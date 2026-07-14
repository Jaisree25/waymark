# infra/envs/prod — M1 PRODUCTION environment (Person C).
# Thin wrapper over modules/stack. Prod is PROTECTED: deletion protection on, regional HA DB, and a
# larger tier. Never carry dev's deletion_protection=false here. Secrets from Secret Manager only.

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
  # backend "gcs" {
  #   bucket = "fsd-benchmark-prod-tfstate"
  #   prefix = "envs/prod"
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

  # Prod: protected + highly available + more DB headroom. Keep uploads longer for investigations.
  deletion_protection        = true
  db_tier                    = "db-custom-2-7680" # 2 vCPU / 7.5GB
  db_availability_type       = "REGIONAL"         # HA: automatic failover to a standby zone
  uploads_lifecycle_age_days = 90
}
