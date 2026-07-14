# infra/envs/staging — M1 STAGING environment (Person C).
# Thin wrapper over modules/stack. Staging mirrors prod's shape but stays disposable/cheap so it can
# be torn down and rebuilt freely. Secrets come from Secret Manager / TF_VAR_*, never committed.

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
  # backend "gcs" {
  #   bucket = "fsd-benchmark-staging-tfstate"
  #   prefix = "envs/staging"
  # }
}

provider "google" {
  project = var.project
  region  = var.region
}

module "stack" {
  source = "../../modules/stack"

  project         = var.project
  region          = var.region
  db_password     = var.db_password
  database_url    = var.database_url
  ingest_image    = var.ingest_image
  aggregate_image = var.aggregate_image
  runner_sa       = var.runner_sa

  # Staging: disposable like dev, but keep raw uploads a little longer for repro of reported issues.
  deletion_protection        = false
  db_tier                    = "db-custom-1-3840"
  db_availability_type       = "ZONAL"
  uploads_lifecycle_age_days = 60
}
