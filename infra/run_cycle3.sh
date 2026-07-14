#!/usr/bin/env bash
#
# run_cycle3 — provision the Cycle-3 GCS resources for one env and run the signed-URL test.
#
# Does the minimal path to prove Cycle 3 against REAL GCP, without paying for Cloud SQL / Cloud Run:
#   1. targeted `terraform apply` of ONLY the uploads bucket + ingest SA + IAM bindings
#   2. read the uploads bucket name from terraform output
#   3. run tests/test_signed_url_roundtrip.py against it (TEST_GCS_BUCKET)
#
# Prereqs (do these once first):
#   ./gc_setup.sh <env>                        # project, billing, APIs, tfstate bucket
#   gcloud auth application-default login      # ADC for Terraform + storage.Client()
#
# Usage:
#   ./run_cycle3.sh [env] [--destroy]
#     env         dev (default) | staging | prod
#     --destroy   tear the Cycle-3 resources back down after the test
#
# Placeholder secrets: the targeted resources don't use db_password/database_url/images, but
# Terraform still requires those variables to have values, so we supply throwaways via TF_VAR_*.
# A real terraform.tfvars, if present, takes precedence over these.

set -euo pipefail

# ---------- logging ----------
if [[ -t 1 ]]; then RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
else RED=; GRN=; YLW=; BLU=; RST=; fi
info() { printf '%s==>%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s ok %s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ---------- args ----------
ENV="dev"; DESTROY=0
for a in "$@"; do
  case "$a" in
    dev|staging|prod) ENV="$a" ;;
    --destroy) DESTROY=1 ;;
    *) die "usage: $0 [dev|staging|prod] [--destroy]" ;;
  esac
done

# Repo-root-relative paths so the script works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/infra/envs/$ENV"
INGEST_DIR="$REPO_ROOT/backend/ingest"
[[ -d "$ENV_DIR" ]] || die "no such env: $ENV_DIR"

# ---------- preflight ----------
command -v gcloud    >/dev/null || die "gcloud not found."
command -v terraform >/dev/null || die "terraform not found."
gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q . \
  || die "no active gcloud account. Run: gcloud auth login"
gcloud auth application-default print-access-token >/dev/null 2>&1 \
  || die "no Application Default Credentials. Run: gcloud auth application-default login"

# Resolve the project: explicit PROJECT env wins, else the active gcloud project.
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT" && "$PROJECT" != "(unset)" ]] || die "no project. Set PROJECT=… or gcloud config set project …"
info "env=$ENV  project=$PROJECT"

# Placeholders for variables the Cycle-3 resources don't touch (real tfvars overrides these).
export TF_VAR_project="$PROJECT"
export TF_VAR_db_password="${TF_VAR_db_password:-unused-in-cycle3}"
export TF_VAR_database_url="${TF_VAR_database_url:-postgresql://unused}"
export TF_VAR_ingest_image="${TF_VAR_ingest_image:-unused}"
export TF_VAR_aggregate_image="${TF_VAR_aggregate_image:-unused}"
export TF_VAR_runner_sa="${TF_VAR_runner_sa:-unused@${PROJECT}.iam.gserviceaccount.com}"

# ---------- targeted apply ----------
TARGETS=(
  -target=module.stack.google_storage_bucket.uploads
  -target=module.stack.google_service_account.ingest
  -target=module.stack.google_storage_bucket_iam_member.ingest_uploads
  -target=module.stack.google_service_account_iam_member.ingest_self_signer
)

cd "$ENV_DIR"
info "terraform init ..."
terraform init -input=false >/dev/null || die "terraform init failed"
info "applying Cycle-3 targets (uploads bucket + ingest SA + IAM) ..."
terraform apply -input=false -auto-approve "${TARGETS[@]}" || die "terraform apply failed"

BUCKET="$(terraform output -raw uploads_bucket)"
[[ -n "$BUCKET" ]] || die "could not read uploads_bucket output"
ok "uploads bucket: $BUCKET"

SIGNER_SA="$(terraform output -raw ingest_sa_email)"
[[ -n "$SIGNER_SA" ]] || die "could not read ingest_sa_email output"
ok "ingest signer SA: $SIGNER_SA"

# Local keyless signing: user ADC can't sign V4 URLs, so we impersonate the ingest SA. That needs
# the running user to hold tokenCreator ON that SA (idempotent to add; may take ~1 min to propagate).
ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
info "granting $ACTIVE_ACCT impersonation on $SIGNER_SA ..."
gcloud iam service-accounts add-iam-policy-binding "$SIGNER_SA" \
  --member="user:$ACTIVE_ACCT" --role="roles/iam.serviceAccountTokenCreator" \
  --condition=None >/dev/null || die "could not grant tokenCreator on the ingest SA"
ok "impersonation granted"

# ---------- run the test ----------
# Pick the venv python (Windows or POSIX layout), else fall back to system python.
if   [[ -x "$INGEST_DIR/.venv/Scripts/python.exe" ]]; then PY="$INGEST_DIR/.venv/Scripts/python.exe"
elif [[ -x "$INGEST_DIR/.venv/bin/python"        ]]; then PY="$INGEST_DIR/.venv/bin/python"
else PY="$(command -v python3 || command -v python)"; warn "no .venv found; using $PY"; fi

cd "$INGEST_DIR"
# The signed-URL test needs google-cloud-storage + httpx; install into the venv if missing.
if ! "$PY" -c "import google.cloud.storage, httpx" >/dev/null 2>&1; then
  info "installing google-cloud-storage + httpx into the venv ..."
  "$PY" -m pip install -q "google-cloud-storage>=2.18" "httpx>=0.27" pytest || die "pip install failed"
fi

info "running the signed-URL roundtrip against $BUCKET (impersonating $SIGNER_SA) ..."
set +e
TEST_GCS_BUCKET="$BUCKET" INGEST_SIGNER_SA="$SIGNER_SA" \
  "$PY" -m pytest -m integration -v tests/test_signed_url_roundtrip.py
RC=$?
set -e

# ---------- optional teardown ----------
if [[ "$DESTROY" -eq 1 ]]; then
  cd "$ENV_DIR"
  info "destroying Cycle-3 targets ..."
  terraform destroy -input=false -auto-approve "${TARGETS[@]}" || warn "destroy failed; clean up manually"
  ok "Cycle-3 resources destroyed"
else
  echo
  info "resources left in place. To remove them later:"
  echo "    cd infra/envs/$ENV && terraform destroy ${TARGETS[*]}"
fi

[[ "$RC" -eq 0 ]] && ok "Cycle 3 green against real GCP ($BUCKET)" || die "Cycle 3 test failed (rc=$RC)"
