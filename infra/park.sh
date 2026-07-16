#!/usr/bin/env bash
#
# park — stop (or restart) the two resources that bill continuously.
#
# Cloud SQL and the Valhalla VM are ~95% of any bill here; everything else (Cloud Run, GCS, Artifact
# Registry, Scheduler) is cents at M1 volume. So "park it between drives" is the whole cost story:
#
#     running ~$90/month   →   parked ~$7/month (disks only)
#
# This is a PAUSE, not a teardown: the database keeps its data and the VM keeps its built tile
# cache. Unparking is this script with `unpark`.
#
# Usage:
#   ./park.sh status [env]     what's running right now (default action)
#   ./park.sh park   [env]     stop the meter
#   ./park.sh unpark [env]     start it again, then wait for the DB to accept connections
#     env: dev (default) | staging | prod
#
# Related: the budget guard (infra/modules/stack/budget.tf) stops the SAME two resources
# automatically if spend crosses the threshold. This script is the habit; the guard is the backstop
# for when you forget. Terraform won't fight either of them — the stack pins activation_policy and
# desired_status under ignore_changes, so an apply can't silently restart what you parked.

set -euo pipefail

if [[ -t 1 ]]; then RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
else RED=; GRN=; YLW=; BLU=; RST=; fi
info() { printf '%s==>%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s ok %s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ---------- args ----------
ACTION="status"
ENV="dev"
for a in "$@"; do
  case "$a" in
    park|unpark|status) ACTION="$a" ;;
    dev|staging|prod)   ENV="$a" ;;
    *) die "usage: $0 [status|park|unpark] [dev|staging|prod]" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/envs/$ENV"
[[ -d "$ENV_DIR" ]] || die "no such env: $ENV_DIR"

command -v gcloud    >/dev/null || die "gcloud not found."
command -v terraform >/dev/null || die "terraform not found."

# ---------- discover what's deployed ----------
# From terraform outputs, not hardcoded names: if the stack changes, this follows it. Reading state
# needs no cloud credentials with the default local backend.
cd "$ENV_DIR"
CONNECTION_NAME="$(terraform output -raw sql_connection_name 2>/dev/null || true)"
[[ -n "$CONNECTION_NAME" ]] || die "no terraform outputs for '$ENV' — is it deployed? (infra/deploy.sh $ENV)"

PROJECT="${CONNECTION_NAME%%:*}"      # project:region:instance
SQL_INSTANCE="${CONNECTION_NAME##*:}"
VM_NAME="$(terraform output -raw valhalla_instance 2>/dev/null || true)"   # empty when disabled
VM_ZONE="$(terraform output -raw valhalla_zone 2>/dev/null || true)"

_sql_policy() {
  gcloud sql instances describe "$SQL_INSTANCE" --project "$PROJECT" \
    --format='value(settings.activationPolicy)' 2>/dev/null || echo "UNKNOWN"
}
_vm_status() {
  gcloud compute instances describe "$VM_NAME" --project "$PROJECT" --zone "$VM_ZONE" \
    --format='value(status)' 2>/dev/null || echo "UNKNOWN"
}

# ---------- status ----------
show_status() {
  local policy vm
  policy="$(_sql_policy)"
  printf '  %-14s %-12s %s\n' "cloud sql" "$SQL_INSTANCE" \
    "$([[ "$policy" == "NEVER" ]] && echo "${GRN}parked${RST} (~\$2/mo)" || echo "${YLW}RUNNING${RST} (~\$51/mo)")"
  if [[ -n "$VM_NAME" ]]; then
    vm="$(_vm_status)"
    printf '  %-14s %-12s %s\n' "valhalla vm" "$VM_NAME" \
      "$([[ "$vm" == "RUNNING" ]] && echo "${YLW}RUNNING${RST} (~\$39/mo)" || echo "${GRN}parked${RST} (~\$5/mo)")"
  else
    printf '  %-14s %-12s %s\n' "valhalla vm" "-" "not deployed (enable_valhalla = false)"
  fi
}

# ---------- park ----------
do_park() {
  if [[ "$(_sql_policy)" == "NEVER" ]]; then
    ok "cloud sql $SQL_INSTANCE already parked"
  else
    info "stopping cloud sql $SQL_INSTANCE ..."
    # Data and disk survive; only the compute stops. Unpark restores it exactly.
    gcloud sql instances patch "$SQL_INSTANCE" --project "$PROJECT" \
      --activation-policy NEVER --quiet >/dev/null || die "could not stop cloud sql"
    ok "cloud sql parked"
  fi

  if [[ -n "$VM_NAME" ]]; then
    if [[ "$(_vm_status)" != "RUNNING" ]]; then
      ok "valhalla vm $VM_NAME already parked"
    else
      info "stopping valhalla vm $VM_NAME ..."
      gcloud compute instances stop "$VM_NAME" --project "$PROJECT" --zone "$VM_ZONE" --quiet \
        >/dev/null || die "could not stop the valhalla vm"
      ok "valhalla vm parked (tile cache kept on disk)"
    fi
  fi

  echo
  ok "parked — roughly \$7/month instead of \$90. Data and tiles are intact."
  warn "while parked the ingest API still answers /healthz, but writes fail: don't park mid-drive."
}

# ---------- unpark ----------
do_unpark() {
  if [[ "$(_sql_policy)" == "ALWAYS" ]]; then
    ok "cloud sql $SQL_INSTANCE already running"
  else
    info "starting cloud sql $SQL_INSTANCE ..."
    gcloud sql instances patch "$SQL_INSTANCE" --project "$PROJECT" \
      --activation-policy ALWAYS --quiet >/dev/null || die "could not start cloud sql"
    ok "cloud sql starting"
  fi

  if [[ -n "$VM_NAME" ]]; then
    if [[ "$(_vm_status)" == "RUNNING" ]]; then
      ok "valhalla vm $VM_NAME already running"
    else
      info "starting valhalla vm $VM_NAME ..."
      gcloud compute instances start "$VM_NAME" --project "$PROJECT" --zone "$VM_ZONE" --quiet \
        >/dev/null || die "could not start the valhalla vm"
      ok "valhalla vm starting"
    fi
  fi

  # Cloud SQL reports RUNNABLE before it actually accepts connections, so waiting here is the
  # difference between "unparked" and "usable" — otherwise the first upload of the drive fails.
  info "waiting for cloud sql to accept connections (up to ~3 min) ..."
  for _ in $(seq 1 36); do
    if [[ "$(gcloud sql instances describe "$SQL_INSTANCE" --project "$PROJECT" \
             --format='value(state)' 2>/dev/null)" == "RUNNABLE" ]]; then
      ok "cloud sql is up"
      break
    fi
    sleep 5
  done

  echo
  ok "unparked. Valhalla rebuilds nothing — its tiles were on the disk."
}

# ---------- go ----------
info "env=$ENV  project=$PROJECT"
case "$ACTION" in
  status) show_status ;;
  park)   do_park ;;
  unpark) do_unpark ;;
esac
