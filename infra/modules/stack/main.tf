# The FSD M1 stack, reused by every environment. See docs/M1/03-backend-gcp.md §7.
# Behaviour that differs per env is driven by variables (deletion_protection, db_tier, HA); resource
# names are stable across envs because each env is a SEPARATE GCP project (no name collisions).

locals {
  # Cloud Run reaches Cloud SQL over the built-in unix socket (/cloudsql/<connection_name>). We
  # construct the DSN here from the instance rather than taking it as an input, so it's always
  # consistent with the DB this stack creates. psycopg (the ingest repo) understands host-as-socket.
  database_url = "postgresql://app:${var.db_password}@/fsd?host=/cloudsql/${google_sql_database_instance.pg.connection_name}"
}

resource "google_sql_database_instance" "pg" {
  name             = "fsd-pg"
  database_version = "POSTGRES_16"
  region           = var.region
  settings {
    tier              = var.db_tier
    availability_type = var.db_availability_type
    ip_configuration { ipv4_enabled = true }
  }
  deletion_protection = var.deletion_protection
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
# device, never proxied through Cloud Run. Short-lived: raw uploads age out per env config.
resource "google_storage_bucket" "uploads" {
  name                        = "${var.project}-uploads"
  location                    = var.region
  uniform_bucket_level_access = true
  lifecycle_rule {
    condition { age = var.uploads_lifecycle_age_days }
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

# The ingest SA needs cloudsql.client to open the Cloud SQL connection from Cloud Run.
resource "google_project_iam_member" "ingest_sql_client" {
  project = var.project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.ingest.email}"
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
        value = local.database_url
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

# Public invocation: the phone (and the smoke tests) reach the ingest API directly; the app enforces
# Firebase auth on /v1 and /healthz is public. Gated so it can be turned off where org policy forbids
# allUsers bindings (domain-restricted sharing).
resource "google_cloud_run_v2_service_iam_member" "ingest_public" {
  count    = var.allow_unauthenticated ? 1 : 0
  name     = google_cloud_run_v2_service.ingest.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# A's nightly pipeline: attribute events → build exposure → score. Gated on enable_aggregate so C can
# deploy the ingest service without A's image existing yet. Turn on once the image is published.
resource "google_cloud_run_v2_job" "aggregate" {
  count    = var.enable_aggregate ? 1 : 0
  name     = "fsd-aggregate"
  location = var.region

  # The pipeline map-matches before it scores, so a job without Valhalla can't attribute anything —
  # it would run at 03:00, gate every road, and look like a data problem rather than a config one.
  # Fail at plan time instead.
  lifecycle {
    precondition {
      condition     = local.valhalla_url != ""
      error_message = "enable_aggregate needs a map-matcher: set enable_valhalla = true, or point valhalla_url at an existing Valhalla."
    }
  }

  template {
    template {
      # Runs as the ingest SA: it already holds cloudsql.client, and the job needs the same database.
      # A dedicated identity would be tighter — worth splitting if the job ever gains other rights.
      service_account = google_service_account.ingest.email
      containers {
        image = var.aggregate_image
        env {
          name  = "DATABASE_URL"
          value = local.database_url
        }
        # The job map-matches (steps 1-2), so it needs Valhalla. Derived from the managed VM when
        # enable_valhalla is on; see local.valhalla_url in valhalla.tf.
        env {
          name  = "VALHALLA_URL"
          value = local.valhalla_url
        }
      }
      volumes {
        name = "cloudsql"
        cloud_sql_instance { instances = [google_sql_database_instance.pg.connection_name] }
      }

      # Valhalla has no external IP, so the job needs a foot inside the VPC to call it. Direct VPC
      # egress rather than a Serverless VPC Access connector: no connector VMs to pay for or size.
      # PRIVATE_RANGES_ONLY keeps the job's other traffic (Cloud SQL, GCS) on the normal path.
      dynamic "vpc_access" {
        for_each = var.enable_valhalla ? [1] : []
        content {
          egress = "PRIVATE_RANGES_ONLY"
          network_interfaces {
            network    = google_compute_network.fsd[0].id
            subnetwork = google_compute_subnetwork.fsd[0].id
          }
        }
      }
    }
  }
}

resource "google_cloud_scheduler_job" "nightly" {
  count    = var.enable_aggregate ? 1 : 0
  name     = "fsd-aggregate-nightly"
  schedule = "0 3 * * *"
  http_target {
    uri         = "https://${var.region}-run.googleapis.com/v2/projects/${var.project}/locations/${var.region}/jobs/fsd-aggregate:run"
    http_method = "POST"
    oauth_token { service_account_email = var.runner_sa }
  }
}
