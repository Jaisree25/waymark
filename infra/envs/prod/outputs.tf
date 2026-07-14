# Re-export the stack module's outputs.

output "uploads_bucket" {
  description = "Bucket for phone-uploaded blobs."
  value       = module.stack.uploads_bucket
}

output "ingest_sa_email" {
  description = "Ingest runtime SA; used by the deployed service to sign upload URLs (keyless)."
  value       = module.stack.ingest_sa_email
}

output "ingest_url" {
  description = "Deployed ingest service URL (for deploy smoke tests)."
  value       = module.stack.ingest_url
}
