# Handles other tooling needs: the signed-URL integration test reads uploads_bucket; deploy/CI reads
# the ingest URL and SA email.

output "uploads_bucket" {
  description = "Bucket for phone-uploaded blobs; set TEST_GCS_BUCKET to this for the roundtrip test."
  value       = google_storage_bucket.uploads.name
}

output "ingest_sa_email" {
  description = "Ingest runtime SA; impersonate it to sign upload URLs locally (keyless)."
  value       = google_service_account.ingest.email
}

output "ingest_url" {
  description = "Deployed ingest service URL (for Cycle 5 deploy smoke tests)."
  value       = google_cloud_run_v2_service.ingest.uri
}
