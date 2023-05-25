terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.60"
    }
  }
}

locals {
  pieces_of_table_name    = split(".", "${var.stage_table_full_name}")
  stream_name             = upper("stream_${local.pieces_of_table_name[2]}_to_${var.name}")
  stream_task_name        = upper("stream_task_${var.name}")
  import_stored_proc_name = upper("stream_import_sp_${var.name}")
}

resource "snowflake_stream" "transactions_stream" {
  name        = local.stream_name
  database    = var.database_name
  schema      = var.schema_name
  comment     = "Stream for changes to the transactions source table"
  
  on_table    = "${var.stage_table_full_name}"
  
  append_only = true
  insert_only = false

  show_initial_rows = var.load_historical_data

  lifecycle {
    ignore_changes = [
      show_initial_rows
    ]
  }
}

resource "snowflake_task" "stream_task" {
  name      = local.stream_task_name
  database  = var.database_name
  schema    = var.schema_name

  user_task_timeout_ms = "3600000" # 1 hour
  comment   = "Load data from external stage to data table on schedule."
  enabled   = true
  schedule  = var.import_interval

  sql_statement = "${var.sql_import_query}"

  when          = "system$stream_has_data('${var.database_name}.${var.schema_name}.${snowflake_stream.transactions_stream.name}')"
}
