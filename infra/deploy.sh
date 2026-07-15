#!/usr/bin/env bash
#
# deploy — build + push the ingest image, apply the env stack, and run the post-deploy smoke tests.
#
# This is the Cycle-5 "deploy the API" flow. It provisions the FULL env (Cloud SQL, buckets, the
# ingest Cloud Run service, IAM), so it is slower and billable — Cloud SQL alone takes ~10 min to
# create the first time. A's nightly aggregate job stays OFF (enable_aggregate=false) so this deploy
# does not depend on A's image.
#
# Prereqs (once): ./gc_setup.sh <env>  and  gcloud auth application-default login
#
# Usage:
#   ./deploy.sh [env] [--no-smoke]
#     env         dev (default) | staging | prod
#     --no-smoke  deploy only; skip the smoke tests
#
# The DB password is generated once and cached in envs/<env>/.db_password (gitignored) so re-runs
# reuse it. DATABASE_URL is derived from the Cloud SQL instance by the stack module.

set -euo pipefail

if [[ -t 1 ]]; then RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
else RED=; GRN=; YLW=; BLU=; RST=; fi
info() { printf '%s==>%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s ok %s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ---------- args ----------
ENV="dev"; RUN_SMOKE=1
for a in "$@"; do
  case "$a" in
    dev|staging|prod) ENV="$a" ;;
    --no-smoke) RUN_SMOKE=0 ;;
    *) die "usage: $0 [dev|staging|prod] [--no-smoke]" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/infra/envs/$ENV"
INGEST_DIR="$REPO_ROOT/backend/ingest"
[[ -d "$ENV_DIR" ]] || die "no such env: $ENV_DIR"

# ---------- preflight ----------
for c in gcloud terraform docker; do command -v "$c" >/dev/null || die "$c not found."; done
gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q . \
  || die "no active gcloud account. Run: gcloud auth login"
if ! ADC_ERR="$(gcloud auth application-default print-access-token 2>&1 >/dev/null)"; then
  [[ -n "$ADC_ERR" ]] && warn "gcloud: $ADC_ERR"
  die "no valid Application Default Credentials. Run: gcloud auth application-default login"
fi
docker info >/dev/null 2>&1 || die "docker daemon not reachable. Start Docker Desktop."

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT" && "$PROJECT" != "(unset)" ]] || die "no project. Set PROJECT=… or gcloud config set project …"
REGION="${REGION:-us-west1}"

# Pick a python for the password generator + running pytest.
if   [[ -x "$INGEST_DIR/.venv/Scripts/python.exe" ]]; then PY="$INGEST_DIR/.venv/Scripts/python.exe"
elif [[ -x "$INGEST_DIR/.venv/bin/python"        ]]; then PY="$INGEST_DIR/.venv/bin/python"
else PY="$(command -v python3 || command -v python)"; fi

# Image tag: the short git sha if available, else 'm1'.
TAG="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo m1)"
IMG="${REGION}-docker.pkg.dev/${PROJECT}/fsd/ingest:${TAG}"
info "env=$ENV  project=$PROJECT  image=$IMG"

# ---------- build + push ----------
info "building image ..."
docker build -t "$IMG" "$INGEST_DIR" || die "docker build failed"
info "configuring docker auth + pushing ..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet >/dev/null 2>&1 || die "configure-docker failed"
docker push "$IMG" || die "docker push failed (is the 'fsd' Artifact Registry repo created? run gc_setup)"
ok "pushed $IMG"

# ---------- db password (generate once, cache gitignored) ----------
PWFILE="$ENV_DIR/.db_password"
if [[ -z "${TF_VAR_db_password:-}" ]]; then
  if [[ -f "$PWFILE" ]]; then
    TF_VAR_db_password="$(cat "$PWFILE")"
  else
    TF_VAR_db_password="$("$PY" -c 'import secrets; print(secrets.token_urlsafe(18))')"
    printf '%s' "$TF_VAR_db_password" > "$PWFILE"
    ok "generated DB password → $PWFILE (gitignored)"
  fi
  export TF_VAR_db_password
fi
export TF_VAR_project="$PROJECT"
export TF_VAR_ingest_image="$IMG"

# ---------- apply the env stack ----------
cd "$ENV_DIR"
warn "provisioning the full $ENV stack (Cloud SQL included — first run ~10 min, billable)"
info "terraform init ..."
terraform init -input=false >/dev/null || die "terraform init failed"
info "terraform apply ..."
terraform apply -input=false -auto-approve || die "terraform apply failed"

URL="$(terraform output -raw ingest_url)"
[[ -n "$URL" ]] || die "could not read ingest_url output"
ok "deployed: $URL"

# ---------- readiness poll ----------
info "waiting for /healthz to serve ..."
READY=0
for _ in $(seq 1 20); do
  if code="$(curl -s -o /dev/null -w '%{http_code}' "$URL/healthz" 2>/dev/null)" && [[ "$code" == "200" ]]; then
    READY=1; break
  fi
  sleep 3
done
[[ "$READY" -eq 1 ]] && ok "service is serving" || warn "healthz not 200 yet; smoke tests will report"

# ---------- smoke ----------
if [[ "$RUN_SMOKE" -eq 1 ]]; then
  cd "$INGEST_DIR"
  "$PY" -c "import httpx" >/dev/null 2>&1 || "$PY" -m pip install -q "httpx>=0.27" pytest
  info "running smoke tests against $URL ..."
  set +e
  INGEST_URL="$URL" "$PY" -m pytest -m smoke -v tests/test_deploy_smoke.py
  RC=$?
  set -e
  echo
  echo "  PostGIS is not enabled by this script. Before real writes, once per instance:"
  echo "    gcloud sql connect fsd-pg --user=app   # then:  CREATE EXTENSION IF NOT EXISTS postgis;"
  [[ "$RC" -eq 0 ]] && ok "Cycle 5 deploy + smoke green ($URL)" || die "smoke tests failed (rc=$RC)"
else
  ok "deployed (smoke skipped). URL: $URL"
fi
