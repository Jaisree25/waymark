# Re-export the stack module's outputs.

output "uploads_bucket" {
  description = "Bucket for phone-uploaded blobs; set TEST_GCS_BUCKET to this for the roundtrip test."
  value       = module.stack.uploads_bucket
}

output "ingest_sa_email" {
  description = "Ingest runtime SA; impersonate it to sign upload URLs locally (keyless)."
  value       = module.stack.ingest_sa_email
}

output "ingest_url" {
  description = "Deployed ingest service URL (for deploy smoke tests)."
  value       = module.stack.ingest_url
}
