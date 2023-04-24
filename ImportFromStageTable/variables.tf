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

variable "database_name" {
  description = "The Snowflake database name."
  type        = string
}

variable "schema_name" {
  description = "The Snowflake schema name."
  type        = string
}

variable "warehouse_name" {
  description = "The Snowflake warehouse name."
  type        = string
}

variable "data_load_task" {
  description = "Parent task which we want to trigger after."
  type        = string
}

variable "stage_table_stream_name" {
  description = "The name of the Snowflake stream that will get populated with changes from the Stage table."
  type        = string
}

variable "after_stream_task" {
  description = "The name of the Snowflake task to load the data on a table after a stream."
  type        = string
}