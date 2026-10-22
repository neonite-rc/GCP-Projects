terraform {
  # 1.9 is the floor: the project uses an `import` block
  # (terraform/imports.tf) to adopt GCP's default `default-allow-ssh`
  # firewall rule, and import blocks are only allowed in the root
  # module. Older versions fail `terraform init` with "An import block
  # was detected in ...".
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # The Cloud Billing Budget API is a BILLING-ACCOUNT-scoped API that
  # still requires a "consumer project" for quota. The google provider
  # 5.x has no `user_project` argument — `billing_project` is the
  # supported way to point the billing API at a project. Without it the
  # provider fails with:
  #   "The billingbudgets.googleapis.com API requires a quota project,
  #    which is not set by default."
  # It is free and does not change where resources are created.
  billing_project = var.project_id
}
