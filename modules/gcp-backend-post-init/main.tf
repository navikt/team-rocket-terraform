terraform {
  backend "gcs" {
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.76.0"
    }
  }
}

data "terraform_remote_state" "default" {
  backend = "gcs"
}

provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

resource "google_storage_bucket" "tf_state_bucket" {
  name          = data.terraform_remote_state.default.outputs.bucket
  location      = var.gcp_region
  storage_class = "STANDARD"
  force_destroy = false

  versioning {
    enabled = true
  }
}
