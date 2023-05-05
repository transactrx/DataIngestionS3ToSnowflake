terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.60"
    }
  }
}

locals {
  warehouse_name          = upper("warehouse_${var.name}")
  pieces_of_table_name    = split(".", "${var.stage_table_full_name}")
  stream_name             = upper("stream_${local.pieces_of_table_name[2]}")
  stream_task_name        = upper("stream_task_${var.name}")
  import_stored_proc_name = upper("stream_import_sp_${var.name}")
}

# resource "snowflake_warehouse" "data_load_warehouse" {
#   name                = local.warehouse_name
#   warehouse_size      = var.warehouse_size
#   auto_suspend        = 60
#   auto_resume         = true
#   initially_suspended = true
# }

resource "snowflake_stream" "transactions_stream" {
  name        = local.stream_name
  database    = var.database_name
  schema      = var.schema_name
  comment     = "Stream for changes to the transactions source table"
  
  on_table    = "${var.stage_table_full_name}"
  
  append_only = true
  insert_only = false

  show_initial_rows = var.load_historical_data
}

# resource "snowflake_procedure" "data_load_sp" {
#   name      = local.import_stored_proc_name
#   database  = var.database_name
#   schema    = var.schema_name
#   return_type = "VARCHAR"
#   language = "JAVASCRIPT"
#   comment = "Store Procedure to load new data comming the transactions table.  It will create the WH if it does not exist and suspend it after execution."
#   execute_as = "CALLER"

#   statement = <<-EOT
#       sql_command = "select system$stream_has_data('${var.database_name}.${var.schema_name}.${snowflake_stream.transactions_stream.name}');";
#       stmt = snowflake.createStatement({ sqlText: sql_command });
#       var rs = stmt.execute();
#       rs.next();
#       var has_data = rs.getColumnValue(1);

#       if (has_data) {
#         sql_command = ${var.sql_import_query}
#         stmt = snowflake.createStatement({ sqlText: sql_command });
#         stmt.execute();

#         return "Data loaded successfully";
#       }
#       else {
#         return "No data to load";
#       }
#   EOT
# }

resource "snowflake_task" "stream_task" {
  name      = local.stream_task_name
  database  = var.database_name
  schema    = var.schema_name
  # warehouse = local.warehouse_name

  user_task_timeout_ms = "3600000" # 1 hour
  comment   = "Load powerline data from external stage to table every hour."
  enabled   = true
  schedule  = var.import_interval

  # sql_statement = "CALL ${var.database_name}.${var.schema_name}.${snowflake_procedure.data_load_sp.name}('${local.warehouse_name}')"
  sql_statement = "${var.sql_import_query}"

  when          = "system$stream_has_data('${var.database_name}.${var.schema_name}.${snowflake_stream.transactions_stream.name}')"

  # depends_on = [
  #   snowflake_procedure.data_load_sp
  #   # snowflake_warehouse.data_load_warehouse
  # ]
}
