# Re-export the stack module's outputs. The signed-URL integration test reads uploads_bucket;
# deploy/CI reads ingest_url and the SA email.

output "uploads_bucket" {
  description = "Bucket for phone-uploaded blobs; set TEST_GCS_BUCKET to this for the roundtrip test."
  value       = module.stack.uploads_bucket
}

output "ingest_sa_email" {
  description = "Ingest runtime SA; impersonate it to sign upload URLs locally (keyless)."
  value       = module.stack.ingest_sa_email
}

output "ingest_url" {
  description = "Deployed ingest service URL (for Cycle 5 deploy smoke tests)."
  value       = module.stack.ingest_url
}

# --- what park.sh needs to find the billable resources ---

output "sql_connection_name" {
  description = "Cloud SQL connection name (project:region:instance)."
  value       = module.stack.sql_connection_name
}

output "valhalla_instance" {
  description = "Valhalla VM name; empty when enable_valhalla is false."
  value       = module.stack.valhalla_instance
}

output "valhalla_zone" {
  description = "Valhalla VM zone; empty when enable_valhalla is false."
  value       = module.stack.valhalla_zone
}
