variable "project" { type = string }
variable "region" {
  type    = string
  default = "us-west1"
}

variable "db_password" {
  type      = string
  sensitive = true # from Secret Manager / TF_VAR_db_password, never committed
}

variable "database_url" {
  type      = string
  sensitive = true
}

variable "ingest_image" { type = string }
variable "aggregate_image" { type = string } # built by Person A's job image; C wires it into infra
variable "runner_sa" { type = string }
