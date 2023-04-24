variable "snowflake_account" {
  description = "The Snowflake account name."
  type        = string
}

variable "snowflake_username" {
  description = "The Snowflake username."
  type        = string
}

variable "snowflake_password" {
  description = "The Snowflake password."
  type        = string
  sensitive   = true
}

variable "snowflake_region" {
  description = "The Snowflake region."
  type        = string
  default     = "us-east-1"
}

variable "snowflake_role" {
  description = "The Snowflake Role to use."
  type        = string
  default     = "SYSADMIN"
}

variable "s3_bucket_name" {
  description = "The name of the S3 bucket containing ndjson.gz files."
  type        = string
}

variable "s3_bucket_prefix" {
  description = "The prefix for the S3 bucket objects."
  type        = string
}

variable "aws_key_id" {
  description = "The AWS Key ID for the S3 bucket access."
  type        = string
}

variable "aws_secret_key" {
  description = "The AWS Secret Key for the S3 bucket access."
  type        = string
  sensitive   = true
}

variable "database_name" {
  description = "The Snowflake database name."
  type        = string
}

variable "schema_name" {
  description = "The Snowflake schema name."
  type        = string
}

variable "stage_name" {
  description = "The Snowflake stage name."
  type        = string
}

variable "table_name" {
  description = "The Snowflake main raw data table name."
  type        = string
}

variable "stored_proc_name" {
  description = "The Snowflake data load stored procedure name."
  type        = string
}

variable "data_load_task_name" {
  description = "The name of the Snowflake task to load the data."
  type        = string
}

variable "data_load_task_interval" {
  description = "Interval to run the data_load_task."
  type = string
  default = "USING CRON 0 * * * *	UTC"
}
