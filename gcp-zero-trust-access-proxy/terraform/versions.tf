terraform {
  required_version = ">= 1.5.0"

  backend "gcs" {
    bucket = "portfolio-vpn-2026-tfstate"
    prefix = "vpn-server"
  }

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
  region  = var.primary_region.region
  zone    = var.primary_region.zone
}
