# Inputs to the FSD stack. Each env (dev/staging/prod) passes its own values; the env-varying
# behaviour knobs (deletion_protection, db_tier, db_availability_type, HA) are what make prod prod.

variable "project" {
  type        = string
  description = "GCP project for this environment, e.g. fsd-benchmark-dev / -staging / -prod."
}

variable "region" {
  type    = string
  default = "us-west1"
}

# --- secrets: from Secret Manager / TF_VAR_*, never committed ---
variable "db_password" {
  type      = string
  sensitive = true
}

# --- image tags + the aggregate runner SA (A's job image; C only wires it) ---
variable "ingest_image" { type = string }

variable "aggregate_image" {
  type        = string
  default     = "" # A's nightly-job image; only required when enable_aggregate = true
  description = "Person A's aggregate job image. Optional until the aggregate job is enabled."
}

variable "runner_sa" {
  type        = string
  default     = "" # only used by the scheduler when enable_aggregate = true
  description = "Service account the scheduler runs the aggregate job as. Optional until enabled."
}

# --- env-varying behaviour: dev/staging are disposable, prod is protected + HA ---
variable "deletion_protection" {
  type        = bool
  default     = true
  description = "Guard the Cloud SQL instance against destroy. false for dev/staging, true for prod."
}

variable "db_tier" {
  type        = string
  default     = "db-custom-1-3840" # 1 vCPU / 3.75GB — fine for dev/staging
  description = "Cloud SQL machine type; give prod more headroom."
}

variable "db_availability_type" {
  type        = string
  default     = "ZONAL" # single zone for dev/staging; REGIONAL (HA) for prod
  description = "ZONAL (single zone) or REGIONAL (high availability, prod)."
}

variable "uploads_lifecycle_age_days" {
  type        = number
  default     = 30
  description = "Delete phone-uploaded blobs after this many days."
}

variable "enable_aggregate" {
  type        = bool
  default     = false
  description = "Create A's nightly aggregate job + scheduler. Off until A's image exists and Valhalla is deployed, so C can deploy the ingest service without either."
}

variable "valhalla_url" {
  type        = string
  default     = ""
  description = "Base URL of the Valhalla map-matching service the nightly job calls (steps 1-2). Required once enable_aggregate is true; Valhalla itself is not yet deployed by this module."
}

variable "allow_unauthenticated" {
  type        = bool
  default     = true
  description = "Make the ingest service publicly invocable (allUsers → run.invoker). The app enforces Firebase auth at /v1; /healthz is public. Set false if org policy forbids allUsers."
}
