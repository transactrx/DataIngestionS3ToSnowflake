resource "snowflake_stream" "pwl_transactions_stream" {
  name        = var.stage_table_stream_name
  database    = var.database_name
  schema      = var.schema_name
  comment     = "Stream for changes to powerline transactions source table"
  
  on_table    = "${var.database_name}.${var.schema_name}.${var.table_name}"
  
  append_only = true
  insert_only = false

  depends_on = [
    snowflake_table.pwl_transactions
  ]
}

resource "snowflake_task" "after_stream_task" {
  name      = var.after_stream_task
  database  = var.database_name
  schema    = var.schema_name
  warehouse = vart.warehouse_name

  user_task_timeout_ms = "3600000" # 1 hour
  comment   = "Load powerline data from external stage to table every hour."
  enabled   = true
  # This will run after the data load task
  after     = [var.data_load_task]

  sql_statement = <<-EOS
    ${var.sql_import_query}
  EOS

  depends_on = [
    snowflake_procedure.pwl_data_load_sp,
    snowflake_warehouse.data_load_warehouse
  ]
}