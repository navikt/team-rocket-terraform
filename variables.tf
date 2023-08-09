variable "gcp_project" {
  description = "The name of the GCP project this should be set up in."
  type = string
}

variable "gcp_region" {
  description = "The name of the GCP region this should be set up in."
  type = string
  default = "europe-north1"
}
