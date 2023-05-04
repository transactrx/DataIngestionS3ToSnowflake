terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.60"
    }
  }
}

locals {
  stage_table_name          = upper("stage_${var.name}")
  external_stage_name     = upper("external_stage_${var.name}")
  warehouse_name          = upper("warehouse_${var.name}")
  import_stored_proc_name = upper("import_sp_${var.name}")
  data_load_task_name     = upper("data_load_task_${var.name}")
}

resource "snowflake_file_format" "ndjson_gz_file_format" {
  name              = "NDJSON_GZ_FILE_FORMAT"
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

  column {
    name = "data"
    type = "VARIANT"
  }
}

resource "snowflake_warehouse" "data_load_warehouse" {
  name                = local.warehouse_name
  warehouse_size      = var.warehouse_size
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
}

resource "snowflake_procedure" "data_load_sp" {
  name      = local.import_stored_proc_name
  database  = var.database_name
  schema    = var.schema_name
  return_type = "VARCHAR"
  language = "JAVASCRIPT"
  comment = "Store Procedure to load new data comming from the S3 bucket and suspending the WH after execution"
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

      sql_command = "COPY INTO ${snowflake_table.transactions_table.name} FROM (SELECT * FROM @${snowflake_stage.external_stage.name})";
      stmt = snowflake.createStatement({ sqlText: sql_command });
      stmt.execute();

      sql_command = "ALTER WAREHOUSE " + whn + " SUSPEND;";
      stmt = snowflake.createStatement({ sqlText: sql_command });
      stmt.execute();

      return "Data loaded successfully";
  EOT
}

resource "snowflake_task" "data_load_task" {
  name      = local.data_load_task_name
  database  = var.database_name
  schema    = var.schema_name
  warehouse = local.warehouse_name
  # This can be a CRON or an interval in minutes
  schedule        = var.data_load_interval
  user_task_timeout_ms = "3600000" # 1 hour
  comment         = "Load powerline data from external stage to table every hour."
  enabled = true

  sql_statement = "CALL ${var.database_name}.${var.schema_name}.${snowflake_procedure.data_load_sp.name}('${local.warehouse_name}')"

  depends_on = [
    snowflake_procedure.data_load_sp
  ]
}
