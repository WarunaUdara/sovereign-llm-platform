terraform {
  required_version = ">= 1.8.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Local state on purpose for a short-lived lab. It is gitignored and must be backed up before
  # any destroy. A remote state bucket is a phase 2 item because it is itself a billable resource.
}

provider "google" {
  project = var.project_id
  region  = var.region
  # Quota and billing project for API calls. Matches the project that owns the resources.
  user_project_override = true
  billing_project       = var.project_id
}
