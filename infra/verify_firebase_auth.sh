#!/usr/bin/env bash
#
# verify_firebase_auth — prove the whole auth path end to end, against the real deployed API.
#
# The setup (console + flutterfire) has many steps and no single "it works" signal. This is that
# signal: it signs a test user in with the Firebase REST API to get a REAL ID token, POSTs to the
# deployed ingest API with it, and checks C's FirebaseAuth accepts it — then checks a request with
# NO token is rejected. If both pass, B's app will authenticate.
#
# Prereqs (all from the README runbook):
#   * enable_firebase_auth applied, or Email/Password enabled in the console
#   * a test user created (email + password)
#   * the API deployed (infra/deploy.sh dev)
#
# Usage:
#   FIREBASE_API_KEY=… TEST_EMAIL=… TEST_PASSWORD=… ./verify_firebase_auth.sh [env]
#     FIREBASE_API_KEY  the Web API key (Firebase console → Project settings → General)
#     env: dev (default) | staging | prod

set -euo pipefail

if [[ -t 1 ]]; then RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'; else RED=; GRN=; YLW=; RST=; fi
ok()   { printf '%s ok %s %s\n' "$GRN" "$RST" "$*"; }
die()  { printf '%sfail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

ENV="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/envs/$ENV"
PY="$SCRIPT_DIR/../backend/ingest/.venv/Scripts/python.exe"
[[ -x "$PY" ]] || PY="$(command -v python3 || command -v python)"

: "${FIREBASE_API_KEY:?set FIREBASE_API_KEY (Firebase console → Project settings → General → Web API key)}"
: "${TEST_EMAIL:?set TEST_EMAIL to a Firebase test user}"
: "${TEST_PASSWORD:?set TEST_PASSWORD for that user}"

# The deployed API URL, from terraform outputs — not hand-typed.
API_URL="$(cd "$ENV_DIR" && terraform output -raw ingest_url 2>/dev/null || true)"
[[ -n "$API_URL" ]] || die "no ingest_url output for '$ENV' — deploy it first (infra/deploy.sh $ENV)"
API_URL="${API_URL%/}"
ok "target API: $API_URL"

# 1. Sign the test user in via the Firebase Auth REST API → a real ID token.
SIGNIN_URL="https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${FIREBASE_API_KEY}"
TOKEN="$(
  "$PY" - "$SIGNIN_URL" "$TEST_EMAIL" "$TEST_PASSWORD" <<'PY'
import json, sys, urllib.request, urllib.error
url, email, password = sys.argv[1], sys.argv[2], sys.argv[3]
body = json.dumps({"email": email, "password": password, "returnSecureToken": True}).encode()
req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
try:
    print(json.load(urllib.request.urlopen(req))["idToken"])
except urllib.error.HTTPError as e:
    sys.stderr.write("sign-in failed: " + e.read().decode() + "\n")
    sys.exit(1)
PY
)" || die "could not sign in the test user — check the API key, the user, and that Email/Password is enabled"
ok "signed in $TEST_EMAIL — got an ID token"

# 2. An UNauthenticated event POST must be rejected (401/403). Proves auth is actually enforced.
code_noauth="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/v1/events" \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: verify' -d '{}')"
[[ "$code_noauth" == "401" || "$code_noauth" == "403" ]] \
  || die "unauthenticated POST returned $code_noauth, expected 401/403 — auth may not be enforced"
ok "no-token request rejected ($code_noauth)"

# 3. The SAME request WITH the real token must get past auth. A bare {} body then fails validation
# (422) — which is the proof we wanted: the token was ACCEPTED, and we didn't reach a 401.
code_auth="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/v1/events" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: verify' -d '{}')"
[[ "$code_auth" == "401" || "$code_auth" == "403" ]] \
  && die "valid token was REJECTED ($code_auth) — C's FIREBASE_PROJECT_ID likely doesn't match the token's project"
ok "valid token accepted (got $code_auth past auth — 422 = reached validation, which is expected here)"

echo
ok "Firebase auth verified end to end: B's app will authenticate against $ENV."
