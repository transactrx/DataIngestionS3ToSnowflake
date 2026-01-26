variable "name" {
  description = "Name of the implementation of this module. This will help identify the resources created by the module."
  type        = string
}
variable "import_interval" {
  description = "Interval to run task to import the data."
  type        = string
  default     = "*/10 * * * * America/New_York"
}

variable "load_historical_data" {
  description = "If true, this will load all the existing data in the source table.  This is true by default."
  type        = bool
  default     = true
}

//These are read from the environment in the github action.

variable "database_name" {
  description = "The Snowflake database name. The database must exist or the module will fail."
  type        = string
}

variable "schema_name" {
  description = "The Snowflake schema name. The schema must exist or the module will fail."
  type        = string
}

variable "stage_table_full_name" {
  description = "The full name (including database and schema) of the Snowflake stage/source table where external data was loaded."
  type        = string
}

variable "sql_import_query" {
  description = "Query to populate the desired table from the stream.  This will most likely be a MERGE query."
  type        = string
}

variable "stream_comment" {
  description = "Comment for the Snowflake stream resource."
  type        = string
  default     = "Stream for changes to the transactions source table"
}

variable "task_comment" {
  description = "Comment for the Snowflake task resource."
  type        = string
  default     = "Load data from external stage to data table on schedule."
}

