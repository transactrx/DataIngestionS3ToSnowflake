variable "name" {
  description = "Name of the implementation of this module. This will help identify the resources created by the module."
  type        = string
}

variable "data_load_interval" {
  description = "Interval to run the data_load_task."
  type        = string
  default     = "USING CRON 0 * * * *	America/New_York"
}

variable "aws_s3_account_key_id" {
  description = "DEPRECATED - prefer storage_integration. The AWS Key ID for the S3 bucket access."
  type        = string
  sensitive   = true
  default     = null
}

variable "aws_s3_account_secret_key" {
  description = "DEPRECATED - prefer storage_integration. The AWS Secret Key for the S3 bucket access."
  type        = string
  sensitive   = true
  default     = null
}

variable "storage_integration" {
  description = "Name of an existing Snowflake storage integration to authenticate the external stage (preferred). When set, the deprecated aws_s3_account_key_id/aws_s3_account_secret_key vars must be omitted."
  type        = string
  default     = null
}

variable "s3_bucket_name" {
  description = "The name of the S3 bucket containing ndjson.gz files."
  type        = string
}

variable "s3_bucket_prefix" {
  description = "The prefix for the S3 bucket objects."
  type        = string
}

variable "database_name" {
  description = "The Snowflake database name. The database must exist or the module will fail."
  type        = string
}

variable "schema_name" {
  description = "The Snowflake schema name. The schema must exist or the module will fail."
  type        = string
}

variable "cluster_by" {
  description = "The field to cluster the table by"
  type        = list(string)
}

