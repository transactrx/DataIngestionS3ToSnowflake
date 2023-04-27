terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.60"
    }
  }
}

locals {
  stream_name             = upper("${var.import_from_stage_table_name}_stream")
  after_stream_task_name  = upper("${var.import_from_stage_table_name}_after_stream_task")
  import_stored_proc_name = upper("${var.import_from_stage_table_name}_after_stream_import_sp")
}

resource "snowflake_stream" "transactions_stream" {
  name        = local.stream_name
  database    = var.database_name
  schema      = var.schema_name
  comment     = "Stream for changes to the transactions source table"
  
  on_table    = "${var.database_name}.${var.schema_name}.${var.stage_table_name}"
  
  append_only = true
  insert_only = false
}

resource "snowflake_procedure" "data_load_sp" {
  name      = local.import_stored_proc_name
  database  = var.database_name
  schema    = var.schema_name
  return_type = "VARCHAR"
  language = "JAVASCRIPT"
  comment = "Store Procedure to load new data comming the transactions table.  It will create the WH if it does not exist and suspend it after execution."
  execute_as = "CALLER"
  
  arguments {
    name = "warehouse_name"
    type = "VARCHAR"
  }

  statement = <<-EOT
      var whn = WAREHOUSE_NAME
      sql_command = "CREATE WAREHOUSE IF NOT EXISTS " + whn + " WITH WAREHOUSE_SIZE = 'LARGE' INITIALLY_SUSPENDED=FALSE AUTO_SUSPEND=60 AUTO_RESUME=TRUE;";

      stmt = snowflake.createStatement({ sqlText: sql_command });
      stmt.execute();

      sql_command = "${var.sql_import_query}"
      stmt = snowflake.createStatement({ sqlText: sql_command });
      stmt.execute();

      sql_command = "ALTER WAREHOUSE " + whn + " SUSPEND;";
      stmt = snowflake.createStatement({ sqlText: sql_command });
      stmt.execute();

      return "Data loaded successfully";
  EOT
}

resource "snowflake_task" "after_stream_task" {
  name      = local.after_stream_task_name
  database  = var.database_name
  schema    = var.schema_name
  warehouse = var.warehouse_name

  user_task_timeout_ms = "3600000" # 1 hour
  comment   = "Load powerline data from external stage to table every hour."
  enabled   = true
  # This will run after the data load task
  after     = [var.data_load_task]

  sql_statement = "CALL ${var.database_name}.${var.schema_name}.${snowflake_procedure.data_load_sp.name}('${var.warehouse_name}')"

  depends_on = [
    snowflake_procedure.data_load_sp
  ]
}
