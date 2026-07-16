# Budget guard — an alert that also acts.
#
# Cloud Billing budget → Pub/Sub → a function that STOPS Cloud SQL and the Valhalla VM. Those two
# bill 24/7 and are ~95% of any bill here; everything else is cents.
#
# Deliberately NOT the usual "disable billing on the project" recipe: Google stops Cloud SQL
# instances whose project loses billing and eventually deletes them. Real drive data costs a weekend
# in a car and can't be regenerated — a surprise invoice is the cheaper mistake. Stopping is
# reversible (see the unpark commands in infra/README.md).
#
# LIMITATION: budget data lags real spend by hours. This is a safety net for "I forgot dev was
# running for three weeks", not a hard real-time cap.
#
# Everything here is gated on billing_account: set it and the guard exists, leave it empty and none
# of this is created (the budget needs the billing account as its parent, and it isn't discoverable
# from inside the project).

locals {
  budget_guard_enabled = var.billing_account != ""
}

resource "google_pubsub_topic" "budget_alerts" {
  count = local.budget_guard_enabled ? 1 : 0
  name  = "fsd-budget-alerts"
}

resource "google_billing_budget" "guard" {
  count           = local.budget_guard_enabled ? 1 : 0
  billing_account = var.billing_account
  display_name    = "fsd-${var.project}-guard"

  budget_filter {
    projects = ["projects/${data.google_project.this[0].number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }

  # Warn early, act late. The 50% and 90% rules are email/console noise that give a human the chance
  # to intervene before the guard does; only the last one crosses the function's shutoff threshold.
  dynamic "threshold_rules" {
    for_each = var.budget_alert_thresholds
    content {
      threshold_percent = threshold_rules.value
    }
  }

  all_updates_rule {
    pubsub_topic                     = google_pubsub_topic.budget_alerts[0].id
    schema_version                   = "1.0"
    disable_default_iam_recipients   = false
    monitoring_notification_channels = var.budget_notification_channels
  }
}

data "google_project" "this" {
  count      = local.budget_guard_enabled ? 1 : 0
  project_id = var.project
}

# --- the function that does the stopping ---

resource "google_service_account" "budget_guard" {
  count        = local.budget_guard_enabled ? 1 : 0
  account_id   = "fsd-budget-guard"
  display_name = "FSD budget guard — stops billable resources at the threshold"
}

# Narrow on purpose: enough to stop these resources, nothing else. Notably NOT billing admin — this
# identity must never be able to disable billing on the project.
resource "google_project_iam_member" "budget_guard_sql" {
  count   = local.budget_guard_enabled ? 1 : 0
  project = var.project
  role    = "roles/cloudsql.editor" # instances.patch, to set activationPolicy = NEVER
  member  = "serviceAccount:${google_service_account.budget_guard[0].email}"
}

resource "google_project_iam_member" "budget_guard_compute" {
  count   = local.budget_guard_enabled ? 1 : 0
  project = var.project
  role    = "roles/compute.instanceAdmin.v1" # instances.stop
  member  = "serviceAccount:${google_service_account.budget_guard[0].email}"
}

data "archive_file" "budget_guard" {
  count       = local.budget_guard_enabled ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/functions/budget_guard"
  output_path = "${path.module}/.build/budget_guard.zip"
  # The tests live beside the source for readability, but they aren't the deployed artefact — and
  # shipping them would make pytest a runtime dependency of the function's build.
  excludes = ["test_main.py", "__pycache__", ".pytest_cache"]
}

resource "google_storage_bucket_object" "budget_guard_source" {
  count = local.budget_guard_enabled ? 1 : 0
  # The hash in the name is what makes a code change redeploy: a stable name would leave the old zip
  # in place and the function silently running yesterday's logic.
  name   = "functions/budget_guard-${data.archive_file.budget_guard[0].output_md5}.zip"
  bucket = google_storage_bucket.artifacts.name
  source = data.archive_file.budget_guard[0].output_path
}

resource "google_cloudfunctions2_function" "budget_guard" {
  count       = local.budget_guard_enabled ? 1 : 0
  name        = "fsd-budget-guard"
  location    = var.region
  description = "Stops Cloud SQL + Valhalla when the budget threshold is crossed"

  build_config {
    runtime     = "python312"
    entry_point = "handle"
    source {
      storage_source {
        bucket = google_storage_bucket.artifacts.name
        object = google_storage_bucket_object.budget_guard_source[0].name
      }
    }
  }

  service_config {
    # One instance: the guard is idempotent, but concurrent stops on the same instance just produce
    # API conflicts and noisy logs for no benefit.
    max_instance_count    = 1
    available_memory      = "256M"
    timeout_seconds       = 120
    service_account_email = google_service_account.budget_guard[0].email
    environment_variables = {
      PROJECT_ID        = var.project
      SQL_INSTANCE      = google_sql_database_instance.pg.name
      VM_NAME           = var.enable_valhalla ? google_compute_instance.valhalla[0].name : ""
      VM_ZONE           = var.enable_valhalla ? local.valhalla_zone : ""
      SHUTOFF_THRESHOLD = tostring(var.budget_shutoff_threshold)
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.budget_alerts[0].id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.budget_guard[0].email
  }
}
