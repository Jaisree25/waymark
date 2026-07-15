variable "project" { type = string }
variable "region" {
  type    = string
  default = "us-west1"
}

variable "db_password" {
  type      = string
  sensitive = true # from Secret Manager / TF_VAR_db_password, never committed
}

variable "ingest_image" { type = string }

# Optional until the nightly aggregate is enabled (A's image). Left empty for ingest-only deploys.
variable "aggregate_image" {
  type    = string
  default = ""
}
variable "runner_sa" {
  type    = string
  default = ""
}
