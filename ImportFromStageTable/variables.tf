variable "import_from_stage_table_name" {
  description = "Name of the implementation of this module."
  type        = string
}

variable "warehouse_name" {
  description = "The Snowflake warehouse name."
  type        = string
}

variable "database_name" {
  description = "The Snowflake database name."
  type        = string
}

variable "schema_name" {
  description = "The Snowflake schema name."
  type        = string
}

variable "data_load_task" {
  description = "Parent task which we want to trigger after."
  type        = string
}

variable "stage_table_name" {
  description = "The name of the Snowflake stage/source table where external data was loaded."
  type        = string
}

variable "sql_import_query" {
  description = "Query to populate the desired table from the stream.  This will most likely be a MERGE query."
  type        = string
} 