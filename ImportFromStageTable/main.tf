terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.60"
      # coconfiguration_aliases = [ snowflake ]
    }
  }
}

resource "snowflake_stream" "pwl_transactions_stream" {
  name        = var.stage_table_stream_name
  database    = var.database_name
  schema      = var.schema_name
  comment     = "Stream for changes to powerline transactions source table"
  
  on_table    = "${var.database_name}.${var.schema_name}.${var.stage_table_name}"
  
  append_only = true
  insert_only = false
}

resource "snowflake_task" "after_stream_task" {
  name      = var.after_stream_task
  database  = var.database_name
  schema    = var.schema_name
  warehouse = var.warehouse_name

  user_task_timeout_ms = "3600000" # 1 hour
  comment   = "Load powerline data from external stage to table every hour."
  enabled   = true
  # This will run after the data load task
  after     = [var.data_load_task]

  sql_statement = "${var.sql_import_query}"
}