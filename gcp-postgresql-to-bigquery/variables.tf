variable "sql_instance_name" {
  description = "The name of the SQL instance containing the database to be used as the source for the Datastream."
  type = string
}

variable "database_name" {
  description = "The name of the database to connect to."
  type = string
}

variable "schemas_to_stream" {
  description = "The schemas, tables and columns that should be streamed. Anything else will be ignored."
  type = map(map(list(string)))

  validation {
    condition = length(var.schemas_to_stream) > 0
    error_message = "At least one schema must be provided"
  }

  validation {
    condition = !contains([for schema, tables in var.schemas_to_stream : length(tables)], 0)
    error_message = "At least one table must be listed under schema"
  }

  validation {
    condition = !contains(flatten([for schema, tables in var.schemas_to_stream : [for table, columns in tables : length(columns)]]), 0)
    error_message = "At least one column must be listed under table"
  }
}

variable "publication_name" {
  description = "The name of the publication."
  type = string
}

variable "replication_slot_name" {
  description = "The name of the replication slot that should be created."
  type = string
}

variable "replication_plugin_name" {
  description = "The name of the logical decoding plugin to use for the replication."
  type = string
  default = "pgoutput"
}
