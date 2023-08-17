terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.76.0"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.20.0"
    }
  }
}

data "google_sql_database_instance" "sql_instance" {
  name = var.sql_instance_name
}

data "google_sql_database" "database" {
  name     = var.database_name
  instance = var.sql_instance_name
}

resource "random_password" "sql_user_admin_password" {
  length = 42
}

resource "google_sql_user" "admin" {
  name     = "bigquery-datastream-admin"
  password = random_password.sql_user_admin_password.result
  instance = data.google_sql_database_instance.sql_instance.name
}

output "database_username" {
  value = google_sql_user.admin.name
}

output "database_password" {
  value = random_password.sql_user_admin_password.result
}

resource "random_password" "sql_user_replicator_password" {
  length = 42
}

resource "postgresql_role" "sql_replication_role" {
  depends_on  = [google_sql_user.admin]
  name        = "bigquery-datastream-replicator"
  password    = random_password.sql_user_replicator_password.result
  login       = true
  replication = true
}

locals {
  columns_to_stream = distinct(flatten([
    for schema, tables in var.schemas_to_stream : [
      for table, columns in tables : {
        schema  = schema
        table   = table
        columns = toset(columns)
      }
      if schema != null && table != null && columns != null && length(columns) > 0
    ]
  ]))
}

#resource "postgresql_grant" "sql_user_permissions" {
#  for_each = {for entry in local.columns_to_stream : "${entry.schema}.${entry.table}" => entry}
#
#  database    = var.database_name
#  role        = postgresql_role.sql_replication_role.name
#  object_type = "column"
#  schema      = each.value.schema
#  objects     = [each.value.table]
#  columns     = each.value.columns
#  privileges  = ["SELECT"]
#}

resource "postgresql_grant_role" "admin_replicator" {
  role       = google_sql_user.admin.name
  grant_role = postgresql_role.sql_replication_role.name
}

#resource "postgresql_publication" "default" {
#  depends_on = [postgresql_grant.sql_user_permissions]
#  name   = var.publication_name
#  owner  = var.publication_owner
#  tables = distinct(flatten([
#    for schema, tables in var.schemas_to_stream : [
#      for table, columns in tables : "${schema}.${table}"
#    ]
#  ]))
#}

resource "postgresql_replication_slot" "default" {
  depends_on = [postgresql_grant_role.admin_replicator, postgresql_role.sql_replication_role]
  name       = var.replication_slot_name
  plugin     = var.replication_plugin_name
}

resource "google_compute_network" "reverse_proxy_vpc" {
  name = "${data.google_sql_database_instance.sql_instance.project}-${var.database_name}-datastream"
}

resource "google_compute_global_address" "reverse_proxy_vpc" {
  name          = "${data.google_sql_database_instance.sql_instance.project}-${var.database_name}-datastream"
  address_type  = "INTERNAL"
  purpose       = "VPC_PEERING"
  network       = google_compute_network.reverse_proxy_vpc.id
  prefix_length = 20
}

resource "google_datastream_private_connection" "reverse_proxy_vpc" {
  display_name          = "${data.google_sql_database_instance.sql_instance.project}-${var.database_name}-datastream"
  private_connection_id = "${data.google_sql_database_instance.sql_instance.project}-${var.database_name}-datastream"
  location              = data.google_sql_database_instance.sql_instance.region

  vpc_peering_config {
    vpc    = google_compute_network.reverse_proxy_vpc.id
    subnet = "10.1.0.0/29"
  }
}

resource "google_compute_firewall" "allow_tcp_cloud_sql" {
  name          = "${data.google_sql_database_instance.sql_instance.project}-${var.database_name}-datastream-tcp"
  network       = google_compute_network.reverse_proxy_vpc.name
  direction     = "INGRESS"
  source_ranges = [google_datastream_private_connection.reverse_proxy_vpc.vpc_peering_config.0.subnet]

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
}

module "cloud_sql_auth_proxy_container_datastream" {
  source         = "terraform-google-modules/container-vm/google"
  version        = "3.1.0"
  cos_image_name = "cos-101-17162-279-6" # https://endoflife.date/cos
  container      = {
    image   = "eu.gcr.io/cloudsql-docker/gce-proxy:1.33.8"
    command = ["/cloud_sql_proxy"]
    args    = [
      "-instances=${data.google_sql_database_instance.sql_instance.connection_name}=tcp:0.0.0.0:5432",
      "-ip_address_types=PRIVATE"
    ]
  }
  restart_policy = "Always"
}

resource "random_string" "reverse_proxy_sa_suffix" {
  length = 4
  special = false
  upper = false
}

resource "google_service_account" "reverse_proxy" {
  account_id   = "datastream-proxy-${random_string.reverse_proxy_sa_suffix.result}"
  description = "The service account for the reverse proxy between Datastream and the SQL instance for ${var.database_name}"
}

resource "google_project_iam_member" "reverse_proxy_sql_client" {
  project = data.google_sql_database_instance.sql_instance.project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.reverse_proxy.email}"
}

resource "google_compute_instance" "reverse_proxy" {
  depends_on = [google_project_iam_member.reverse_proxy_sql_client]
  name         = "${data.google_sql_database_instance.sql_instance.project}-${var.database_name}-ds-proxy"
  machine_type = "e2-medium"
  zone         = var.reverse_proxy_zone

  boot_disk {
    initialize_params {
      image = module.cloud_sql_auth_proxy_container_datastream.source_image
    }
  }

  network_interface {
    network = google_compute_network.reverse_proxy_vpc.name
    access_config {
    }
  }

  service_account {
    email  = google_service_account.reverse_proxy.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    gce-container-declarations = module.cloud_sql_auth_proxy_container_datastream.metadata_value
    google-logging-enabled     = "true"
    google-monitoring-enabled  = "false"
  }

  labels = {
    container-vm = module.cloud_sql_auth_proxy_container_datastream.vm_container_label
  }
}

resource "google_datastream_connection_profile" "source" {
  depends_on            = [postgresql_replication_slot.default]
  #  depends_on            = [postgresql_replication_slot.default, postgresql_publication.default]
  display_name          = "${var.database_name} source (PostgreSQL)"
  location              = data.google_sql_database_instance.sql_instance.region
  connection_profile_id = "${var.database_name}-source"

  postgresql_profile {
    hostname = google_compute_instance.reverse_proxy.network_interface[0].network_ip
    port     = 5432
    database = data.google_sql_database.database.name
    username = postgresql_role.sql_replication_role.name
    password = random_password.sql_user_replicator_password.result
  }

  private_connectivity {
    private_connection = google_datastream_private_connection.reverse_proxy_vpc.id
  }
}

resource "google_datastream_connection_profile" "destination" {
  display_name          = "${var.database_name} destination (BigQuery)"
  location              = data.google_sql_database_instance.sql_instance.region
  connection_profile_id = "${var.database_name}-destination"

  bigquery_profile {
  }
}

resource "google_datastream_stream" "stream" {
  display_name  = "${var.database_name} (PostgreSQL) to BigQuery"
  location      = data.google_sql_database_instance.sql_instance.region
  stream_id     = "${var.database_name}-to-bigquery-stream"
  desired_state = "RUNNING"

  source_config {
    source_connection_profile = google_datastream_connection_profile.source.id
    postgresql_source_config {
      publication      = var.publication_name
      replication_slot = var.replication_slot_name
      include_objects {
        dynamic "postgresql_schemas" {
          for_each = var.schemas_to_stream
          content {
            schema = postgresql_schemas.key
            dynamic "postgresql_tables" {
              for_each = postgresql_schemas.value
              content {
                table = postgresql_tables.key
                dynamic "postgresql_columns" {
                  for_each = postgresql_tables.value
                  content {
                    column = postgresql_columns.value
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.destination.id
    bigquery_destination_config {
      data_freshness = "3600s"
      source_hierarchy_datasets {
        dataset_template {
          location = data.google_sql_database_instance.sql_instance.region
        }
      }
    }
  }

  backfill_all {
  }
}
