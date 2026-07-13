# infra/envs/dev — M1 dev environment (Person C).
# Minimum set from docs/M1/03-backend-gcp.md §7. `terraform validate` + `plan` must be clean in CI.
# db_password comes from Secret Manager / TF_VAR — never a committed tfvars.

terraform {
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
  # Remote state in the tfstate bucket (bootstrap it once, then uncomment):
  # backend "gcs" { bucket = "PROJECT-tfstate" prefix = "envs/dev" }
}

provider "google" {
  project = var.project
  region  = var.region
}

resource "google_sql_database_instance" "pg" {
  name             = "fsd-pg"
  database_version = "POSTGRES_16"
  region           = var.region
  settings {
    tier = "db-custom-1-3840" # 1 vCPU / 3.75GB — small is fine for M1
    ip_configuration { ipv4_enabled = true }
  }
  deletion_protection = false # dev only
}

resource "google_sql_database" "fsd" {
  name     = "fsd"
  instance = google_sql_database_instance.pg.name
}

resource "google_sql_user" "app" {
  name     = "app"
  instance = google_sql_database_instance.pg.name
  password = var.db_password
}

resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project}-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
}

resource "google_storage_bucket" "osm" {
  name                        = "${var.project}-osm"
  location                    = var.region
  uniform_bucket_level_access = true
}

# Phone-uploaded blobs (event audio/sensors) land here via V4 signed PUT URLs — direct from the
# device, never proxied through Cloud Run. Short-lived: raw uploads age out after 30 days.
resource "google_storage_bucket" "uploads" {
  name                        = "${var.project}-uploads"
  location                    = var.region
  uniform_bucket_level_access = true
  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }
}

# Runtime identity for the ingest service. It mints the signed URLs and owns the uploads objects.
resource "google_service_account" "ingest" {
  account_id   = "fsd-ingest"
  display_name = "FSD ingest API (Cloud Run) — signs upload URLs, writes uploads bucket"
}

# The ingest SA reads/writes only the uploads bucket (not artifacts/osm).
resource "google_storage_bucket_iam_member" "ingest_uploads" {
  bucket = google_storage_bucket.uploads.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ingest.email}"
}

# Keyless V4 signing: let the SA sign blobs by calling IAM SignBlob on ITSELF, so no private key
# file is ever downloaded or committed. On Cloud Run the runtime SA has no key; this self-binding is
# what lets generate_signed_url() work. To sign locally, impersonate this SA (also needs this role).
resource "google_service_account_iam_member" "ingest_self_signer" {
  service_account_id = google_service_account.ingest.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.ingest.email}"
}

resource "google_cloud_run_v2_service" "ingest" {
  name     = "fsd-ingest"
  location = var.region
  template {
    service_account = google_service_account.ingest.email
    containers {
      image = var.ingest_image
      env {
        name  = "DATABASE_URL"
        value = var.database_url
      }
      env {
        name  = "GCS_BUCKET"
        value = google_storage_bucket.uploads.name
      }
      env {
        name  = "FIREBASE_PROJECT_ID"
        value = var.project
      }
    }
    volumes {
      name = "cloudsql"
      cloud_sql_instance { instances = [google_sql_database_instance.pg.connection_name] }
    }
  }
}

resource "google_cloud_run_v2_job" "aggregate" {
  name     = "fsd-aggregate"
  location = var.region
  template {
    template {
      containers { image = var.aggregate_image }
    }
  }
}

resource "google_cloud_scheduler_job" "nightly" {
  name     = "fsd-aggregate-nightly"
  schedule = "0 3 * * *"
  http_target {
    uri         = "https://${var.region}-run.googleapis.com/v2/projects/${var.project}/locations/${var.region}/jobs/fsd-aggregate:run"
    http_method = "POST"
    oauth_token { service_account_email = var.runner_sa }
  }
}
