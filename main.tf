terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.76.0"
    }
  }
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

resource "google_storage_bucket" "tf_state_bucket" {
  name          = "${var.gcp_project}-terraform-state"
  location      = var.gcp_region
  storage_class = "STANDARD"
  force_destroy = false

  versioning {
    enabled = true
  }
}
