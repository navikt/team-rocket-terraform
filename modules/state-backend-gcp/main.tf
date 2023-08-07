terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = ">= 4.76.0"
    }
  }
}

data "google_client_config" "default" {
}

resource "google_storage_bucket" "tf_state_bucket" {
  name          = "${data.google_client_config.default.project}-terraform-state"
  location      = data.google_client_config.default.region
  storage_class = "STANDARD"
  force_destroy = false

  versioning {
    enabled = true
  }
}
