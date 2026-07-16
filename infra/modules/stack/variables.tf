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

# --- budget guard ---
variable "billing_account" {
  type        = string
  default     = ""
  description = "Billing account ID (e.g. 0X0X0X-0X0X0X-0X0X0X). Set it to create the budget + auto-shutoff guard; leave empty and none of that is created. The budget's parent is the billing account, which isn't discoverable from inside the project."
}

variable "budget_amount_usd" {
  type        = number
  default     = 50
  description = "Monthly budget. Crossing budget_shutoff_threshold of this stops Cloud SQL + Valhalla."
}

variable "budget_alert_thresholds" {
  type        = list(number)
  default     = [0.5, 0.9, 1.0]
  description = "Fractions of the budget that raise alerts. The early ones are a human's warning; only budget_shutoff_threshold triggers the stop."
}

variable "budget_shutoff_threshold" {
  type        = number
  default     = 1.0
  description = "Fraction of the budget at which the guard stops billable resources. 1.0 = at budget."
}

variable "budget_notification_channels" {
  type        = list(string)
  default     = []
  description = "Optional Monitoring notification channels to also alert. Billing admins are emailed regardless."
}

# --- Valhalla (map-matching) ---
variable "enable_valhalla" {
  type        = bool
  default     = false
  description = "Deploy the Valhalla VM + its VPC. Off by default: a VM bills continuously whether the nightly runs or not. Turn on for Checkpoint 2, when the pipeline needs a real matcher."
}

variable "valhalla_url" {
  type        = string
  default     = ""
  description = "Override for the nightly job's VALHALLA_URL. Ignored when enable_valhalla is true — the URL is then derived from the managed instance so it can't drift."
}

variable "valhalla_machine_type" {
  type        = string
  default     = "e2-standard-2" # 2 vCPU / 8GB — the size docs/M1/03-backend-gcp.md §5 suggests
  description = "Valhalla VM size. M1's SF/norcal tile set is small; scale up only if matching is slow."
}

variable "valhalla_disk_gb" {
  type        = number
  default     = 50
  description = "Boot disk size. Must hold the OSM extract plus the built tiles."
}

variable "valhalla_upstream_image" {
  type        = string
  default     = "gis-ops/docker-valhalla/valhalla:latest"
  description = "The Valhalla image's path WITHIN ghcr.io (OSS). Pulled through the Artifact Registry mirror, because the VM has no external IP and can't reach ghcr.io directly. Pin a digest before anything you rely on."
}

variable "valhalla_image" {
  type        = string
  default     = ""
  description = "Full image override for the Valhalla VM. Leave empty to use the ghcr.io mirror. If you set this, it must be an address the VM can actually reach with no external IP — i.e. *.pkg.dev or gcr.io, never ghcr.io/docker.io."
}

variable "valhalla_zone" {
  type        = string
  default     = ""
  description = "Zone for the Valhalla VM. Defaults to <region>-a."
}

variable "valhalla_subnet_cidr" {
  type        = string
  default     = "10.10.0.0/24"
  description = "Subnet the Valhalla VM and the nightly job's VPC egress share."
}

variable "allow_unauthenticated" {
  type        = bool
  default     = true
  description = "Make the ingest service publicly invocable (allUsers → run.invoker). The app enforces Firebase auth at /v1; /healthz is public. Set false if org policy forbids allUsers."
}
