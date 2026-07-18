#!/usr/bin/env bash
#
# gc_setup — bootstrap a GCP project for one FSD-Benchmark environment (Person C).
#
# Does the one-time, pre-Terraform steps from docs/M1/01-environment-setup.md §4:
#   create project → link billing → enable APIs → tfstate bucket → Artifact Registry.
# Terraform (infra/envs/<env>) manages everything after this. Safe to re-run: every step is
# idempotent (checks before it creates).
#
# Usage:
#   ./gc_setup.sh <env> [project_id]
#     <env>        dev | staging | prod
#     [project_id] override the default fsd-benchmark-<env> (project IDs are GLOBALLY unique;
#                  pass a suffixed id here if the default is taken)
#
# Environment overrides:
#   BILLING   billing account id (e.g. 0X0X0X-0X0X0X-0X0X0X). If unset, the script tries to
#             auto-pick your first OPEN billing account; if none, it skips linking and warns.
#   REGION    default us-west1
#   ORG_ID    optional organization id to create the project under
#
# Prereqs: gcloud installed and `gcloud auth login` already done. This script does NOT run
# `gcloud auth application-default login` for you — do that once after, for Terraform + tests.

set -euo pipefail

# ---------- pretty logging ----------
if [[ -t 1 ]]; then RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
else RED=; GRN=; YLW=; BLU=; RST=; fi
info() { printf '%s==>%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s ok %s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ---------- args ----------
ENV="${1:-}"
case "$ENV" in
  dev|staging|prod) ;;
  *) die "usage: $0 <dev|staging|prod> [project_id]" ;;
esac

PROJECT="${2:-fsd-benchmark-$ENV}"
REGION="${REGION:-us-west1}"
BILLING="${BILLING:-}"
ORG_ID="${ORG_ID:-}"

command -v gcloud >/dev/null || die "gcloud not found; install the Google Cloud SDK first."

# Must be logged in (this script can't run the interactive browser flow).
if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  die "no active gcloud account. Run: gcloud auth login"
fi
ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"

info "Environment : $ENV"
info "Project     : $PROJECT"
info "Region      : $REGION"
info "Account     : $ACTIVE_ACCT"
echo

# ---------- 1. project ----------
if gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
  ok "project $PROJECT already exists"
else
  info "creating project $PROJECT ..."
  # shellcheck disable=SC2086  # ORG_ID flag is intentionally word-split (empty = omitted)
  gcloud projects create "$PROJECT" ${ORG_ID:+--organization="$ORG_ID"} \
    || die "project create failed (id may be taken globally — pass a unique [project_id])"
  ok "created $PROJECT"
fi

gcloud config set project "$PROJECT" >/dev/null
ok "gcloud config project set to $PROJECT"

# ---------- 2. billing ----------
if [[ -z "$BILLING" ]]; then
  BILLING="$(gcloud billing accounts list --filter=open=true \
             --format='value(name)' 2>/dev/null | head -1 | sed 's#billingAccounts/##')"
fi
if [[ -z "$BILLING" ]]; then
  warn "no billing account found/provided. Set BILLING=<id> and re-run; APIs need billing linked."
else
  if gcloud billing projects describe "$PROJECT" \
       --format='value(billingEnabled)' 2>/dev/null | grep -qi true; then
    ok "billing already linked"
  else
    info "linking billing account $BILLING ..."
    gcloud billing projects link "$PROJECT" --billing-account "$BILLING" >/dev/null \
      || die "billing link failed (check the account id and your permissions)"
    ok "billing linked"
  fi
fi

# ---------- 3. APIs ----------
# Full M1 set (03-backend-gcp) + iamcredentials for keyless V4 signed-URL signing (Cycle 3).
APIS=(
  run.googleapis.com
  sqladmin.googleapis.com
  storage.googleapis.com
  artifactregistry.googleapis.com
  cloudscheduler.googleapis.com
  cloudbuild.googleapis.com
  secretmanager.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com   # SignBlob API — powers keyless signed URLs
  compute.googleapis.com
  pubsub.googleapis.com           # budget alerts -> the shutoff guard
  cloudfunctions.googleapis.com   # the guard itself
  eventarc.googleapis.com         # delivers Pub/Sub to the gen2 function
  billingbudgets.googleapis.com   # the budget resource
  identitytoolkit.googleapis.com  # Firebase Auth / Identity Platform (token verify + email/password)
)
info "enabling ${#APIS[@]} APIs (idempotent; may take a minute) ..."
gcloud services enable "${APIS[@]}" >/dev/null || die "enabling APIs failed"
ok "APIs enabled"

# ---------- 4. Terraform state bucket ----------
TFSTATE="gs://${PROJECT}-tfstate"
if gcloud storage buckets describe "$TFSTATE" >/dev/null 2>&1; then
  ok "tfstate bucket $TFSTATE already exists"
else
  info "creating tfstate bucket $TFSTATE ..."
  gcloud storage buckets create "$TFSTATE" --location="$REGION" \
    --uniform-bucket-level-access >/dev/null || die "tfstate bucket create failed"
  ok "created $TFSTATE"
fi
gcloud storage buckets update "$TFSTATE" --versioning >/dev/null
ok "tfstate versioning on"

# ---------- 5. Artifact Registry ----------
if gcloud artifacts repositories describe fsd --location="$REGION" >/dev/null 2>&1; then
  ok "Artifact Registry repo 'fsd' already exists"
else
  info "creating Artifact Registry repo 'fsd' ..."
  gcloud artifacts repositories create fsd \
    --repository-format=docker --location="$REGION" \
    --description="FSD benchmark images" >/dev/null || die "Artifact Registry create failed"
  ok "created repo 'fsd'"
fi

# ---------- done ----------
echo
ok "bootstrap complete for '$ENV' ($PROJECT)"
cat <<EOF

${GRN}Next steps${RST}
  1. Application Default Credentials (for Terraform + the signed-URL test):
       gcloud auth application-default login

  2. Enable the GCS backend in infra/envs/$ENV/main.tf (uncomment the backend "gcs" block —
     bucket is already created: ${PROJECT}-tfstate).

  3. Provision with Terraform:
       cd infra/envs/$ENV
       cp terraform.tfvars.example terraform.tfvars   # set project + secrets (or use TF_VAR_*)
       terraform init
       terraform plan

  To test ONLY Cycle 3 (signed URLs) without paying for Cloud SQL/Cloud Run:
       terraform apply \\
         -target=module.stack.google_storage_bucket.uploads \\
         -target=module.stack.google_service_account.ingest \\
         -target=module.stack.google_storage_bucket_iam_member.ingest_uploads \\
         -target=module.stack.google_service_account_iam_member.ingest_self_signer
       export TEST_GCS_BUCKET=\$(terraform output -raw uploads_bucket)
       cd ../../../backend/ingest && pytest -m integration tests/test_signed_url_roundtrip.py
EOF
