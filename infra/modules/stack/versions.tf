# Provider requirements for the shared stack module. The provider CONFIG (project/region) lives in
# each env root, not here — a module declares what it needs, the root configures it.
terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    # Zips the budget-guard function source at plan time, so the function's code is versioned with
    # the infra that deploys it rather than uploaded by hand.
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}
