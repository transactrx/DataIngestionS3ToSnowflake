terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.60"
    }
  }
}

locals {
  stage_table_name        = upper("stage_${var.name}")
  external_stage_name     = upper("external_stage_${var.name}")
  import_stored_proc_name = upper("import_sp_${var.name}")
  data_load_task_name     = upper("data_load_task_${var.name}")
  file_format_name        = upper("NDJSON_GZ_FORMAT_${var.name}")
}

resource "snowflake_file_format" "ndjson_gz_file_format" {
  name              = local.file_format_name
  database          = var.database_name
  schema            = var.schema_name
  compression       = "AUTO"

  binary_format     = "HEX"
  date_format       = "AUTO"
  time_format       = "AUTO"
  timestamp_format  = "AUTO"

  format_type       = "JSON"
}

resource "snowflake_stage" "external_stage" {
  name     = local.external_stage_name
  database = var.database_name
  schema   = var.schema_name
  url      = "s3://${var.s3_bucket_name}/${var.s3_bucket_prefix}"

  credentials = "AWS_KEY_ID='${var.aws_s3_account_key_id}' AWS_SECRET_KEY='${var.aws_s3_account_secret_key}'"

  file_format = "FORMAT_NAME = ${var.database_name}.${var.schema_name}.${snowflake_file_format.ndjson_gz_file_format.name}"
}

resource "snowflake_table" "transactions_table" {
  database        = var.database_name
  schema          = var.schema_name
  name            = local.stage_table_name
  change_tracking = true
  cluster_by      = var.cluster_by

  column {
    name = "DATA"
    type = "VARIANT"
  }
  column {
    name = "INGESTED_TIMESTAMP"
    type = "TIMESTAMP_NTZ(9)"
    default {
      expression = "CURRENT_TIMESTAMP()"
    }
  }
  lifecycle {
    ignore_changes = [cluster_by]
  }
}

resource "snowflake_task" "data_load_task" {
  name      = local.data_load_task_name
  database  = var.database_name
  schema    = var.schema_name
  # This can be a CRON or an interval in minutes
  schedule        = var.data_load_interval
  user_task_timeout_ms = "3600000" # 1 hour
  comment         = "Load powerline data from external stage to table every hour."
  enabled = true

  sql_statement = "COPY INTO ${snowflake_table.transactions_table.name} (DATA) FROM (SELECT $1 FROM @${snowflake_stage.external_stage.name})"
}
