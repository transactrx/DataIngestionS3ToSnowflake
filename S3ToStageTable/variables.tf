variable "s3_to_stage_import_name" {
  description = "Name of the implementation of this module."
  type        = string
}

variable "s3_bucket_name" {
  description = "The name of the S3 bucket containing ndjson.gz files."
  type        = string
}

variable "s3_bucket_prefix" {
  description = "The prefix for the S3 bucket objects."
  type        = string
}

variable "warehouse_size" {
  description = "The size for the Snowflake data warehouse."
  type = string
  default = "LARGE"
}

variable "database_name" {
  description = "The Snowflake database name."
  type        = string
}

variable "schema_name" {
  description = "The Snowflake schema name."
  type        = string
}

variable "table_name" {
  description = "The Snowflake main raw data table name."
  type        = string
}

variable "data_load_interval" {
  description = "Interval to run the data_load_task."
  type = string
  default = "USING CRON 0 * * * *	UTC"
}
