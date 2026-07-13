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

resource "google_cloud_run_v2_service" "ingest" {
  name     = "fsd-ingest"
  location = var.region
  template {
    containers {
      image = var.ingest_image
      env {
        name  = "DATABASE_URL"
        value = var.database_url
      }
      env {
        name  = "GCS_BUCKET"
        value = google_storage_bucket.artifacts.name
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
