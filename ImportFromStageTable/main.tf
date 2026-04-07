terraform {
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 0.99.0"
    }
  }
}

locals {
  stream_name             = upper("stream_${var.name}")
  stream_name_full        = "${var.database_name}.${var.schema_name}.${local.stream_name}"
  stream_task_name        = upper("stream_task_${var.name}")
  import_stored_proc_name = upper("stream_import_sp_${var.name}")
}

resource "snowflake_stream_on_table" "transactions_stream" {
  name     = local.stream_name
  database = var.database_name
  schema   = var.schema_name
  comment  = var.stream_comment

  table = var.stage_table_full_name

  append_only = "true"
  copy_grants = true

  show_initial_rows = var.load_historical_data

  lifecycle {
    ignore_changes = [
      show_initial_rows
    ]
  }
}

locals {
  fixed_import_query = replace(var.sql_import_query, "$$$STREAM$$$", local.stream_name_full)
}

resource "snowflake_task" "stream_task" {
  name                     = local.stream_task_name
  database                 = var.database_name
  schema                   = var.schema_name
  task_auto_retry_attempts = var.task_after == null ? var.auto_retry_attempts : null
  error_integration        = var.task_after == null ? var.error_integration : null
  user_task_timeout_ms     = var.user_task_timeout_ms
  comment                  = var.task_comment
  started                  = true

  allow_overlapping_execution = false

  after = var.task_after
  dynamic "schedule" {
    # Schedule is mutually exclusive with after
    for_each = var.task_after == null ? [1] : []
    content {
      using_cron = var.import_interval
    }
  }

  sql_statement = local.fixed_import_query

  when = "system$stream_has_data('${local.stream_name_full}')"
}
