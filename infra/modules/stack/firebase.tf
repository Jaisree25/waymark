# Firebase Auth (Identity Platform) — the ingest API authenticates every write with a Firebase ID
# token (docs/M1/01-environment-setup.md §5). B's app signs the user in; C's FirebaseAuth verifies
# the token via the Admin SDK. This codifies the ONE part of that which is Terraform-able: enabling
# the email/password sign-in provider, so it isn't a console click (the "no click-ops" rule).
#
# What Terraform CANNOT do, and stays a console/CLI step (see the runbook in the README):
#   * registering the Android/iOS apps and downloading google-services.json / GoogleService-Info.plist
#   * creating test users
# Those are Firebase-project operations, not GCP resources.
#
# Gated on enable_firebase_auth (default off): the first-ever enablement of Identity Platform in a
# project sometimes has to be kicked off once in the console, and it needs billing + the
# identitytoolkit API. Leaving it opt-in means the simple console path still works for anyone who
# prefers it, and this doesn't block a plan in a project that hasn't provisioned Identity Platform.

resource "google_identity_platform_config" "auth" {
  count   = var.enable_firebase_auth ? 1 : 0
  project = var.project

  sign_in {
    # Email/Password is what B's app uses. Passwords are required (no email-link sign-in in M1).
    email {
      enabled           = true
      password_required = true
    }
  }

  # The domains Firebase will mint/verify tokens for. localhost is here so the app can be exercised
  # against a local backend during development; the app's real hosts get added as they exist.
  authorized_domains = concat(["localhost", "${var.project}.firebaseapp.com"], var.firebase_authorized_domains)
}
