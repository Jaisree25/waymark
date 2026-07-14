# infra/envs/dev — M1 DEV environment (Person C).
# Thin wrapper over modules/stack. Dev is disposable: no deletion protection, single-zone DB.
# db_password / database_url come from Secret Manager / TF_VAR_*, never a committed tfvars.

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
  # Remote state in the tfstate bucket (bootstrap it once, then uncomment):
  # backend "gcs" {
  #   bucket = "fsd-benchmark-dev-tfstate"
  #   prefix = "envs/dev"
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

  # Dev: disposable + cheap.
  deletion_protection  = false
  db_tier              = "db-custom-1-3840"
  db_availability_type = "ZONAL"
}
