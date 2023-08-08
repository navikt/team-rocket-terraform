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

resource "random_password" "sql_user_postgres_password" {
  length = 42
}

resource "google_sql_user" "postgres" {
  name     = "postgres"
  password = random_password.sql_user_postgres_password.result
  instance = data.google_sql_database_instance.sql_instance.name
}

output "postgres_password" {
  value = random_password.sql_user_postgres_password.result
}

resource "random_password" "sql_user_datastream_password" {
  length = 42
}

resource "google_sql_user" "datastream" {
  name     = "bigquery-datastream"
  password = random_password.sql_user_datastream_password.result
  instance = data.google_sql_database_instance.sql_instance.name
}

resource "postgresql_role" "sql_replication_role" {
  depends_on = [google_sql_user.postgres]
  name        = "replicator"
  replication = true
}

resource "postgresql_role" "sql_superuser_role" {
  depends_on = [google_sql_user.postgres]
  name        = "superuser"
  superuser = true
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

resource "postgresql_grant" "sql_user_permissions" {
  depends_on = [google_sql_user.postgres]
  for_each = {for entry in local.columns_to_stream : "${entry.schema}.${entry.table}" => entry}

  database    = var.database_name
  role        = postgresql_role.sql_replication_role.name
  object_type = "column"
  schema      = each.value.schema
  objects     = [each.value.table]
  columns     = each.value.columns
  privileges  = ["SELECT"]
}

resource "postgresql_grant_role" "replicator_grant" {
  depends_on = [google_sql_user.postgres]
  role       = google_sql_user.datastream.name
  grant_role = postgresql_role.sql_replication_role.name
}

resource "postgresql_grant_role" "superuser_grant" {
  depends_on = [google_sql_user.postgres]
  role       = google_sql_user.postgres.name
  grant_role = postgresql_role.sql_superuser_role.name
}

resource "postgresql_publication" "publication" {
  depends_on = [google_sql_user.postgres]
  name   = var.publication_name
  tables = distinct(flatten([
    for schema, tables in var.schemas_to_stream : [
      for table, columns in tables : "${schema}.${table}"
    ]
  ]))
}

resource "postgresql_replication_slot" "default" {
  depends_on = [postgresql_grant_role.superuser_grant]
  name   = var.replication_slot_name
  plugin = var.replication_plugin_name
}

resource "google_datastream_connection_profile" "source" {
  depends_on = [postgresql_replication_slot.default, postgresql_publication.publication]
  display_name          = "Source (PostgreSQL)"
  location              = data.google_sql_database_instance.sql_instance.region
  connection_profile_id = "source"

  postgresql_profile {
    hostname = data.google_sql_database_instance.sql_instance.public_ip_address
    port     = 5432
    database = data.google_sql_database.database.name
    username = google_sql_user.datastream.name
    password = random_password.sql_user_datastream_password.result
  }
}

resource "google_datastream_connection_profile" "destination" {
  display_name          = "Destination (BigQuery)"
  location              = data.google_sql_database_instance.sql_instance.region
  connection_profile_id = "destination"

  bigquery_profile {
  }
}

resource "google_datastream_stream" "stream" {
  display_name  = "PostgreSQL to BigQuery Stream"
  location      = data.google_sql_database_instance.sql_instance.region
  stream_id     = "stream"
  desired_state = "RUNNING"

  source_config {
    source_connection_profile = google_datastream_connection_profile.source.id
    postgresql_source_config {
      publication      = postgresql_publication.publication.name
      replication_slot = postgresql_replication_slot.default.name
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
      data_freshness = "900s"
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
