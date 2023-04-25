terraform {
  required_providers {
    snowflake = {
      source  = "Snowflake-Labs/snowflake"
      version = "~> 0.60"
    }
  }
}

resource "snowflake_database" "this" {
  name = var.database_name
}

resource "snowflake_schema" "this" {
  name       = var.schema_name
  database   = snowflake_database.this.name
}

resource "snowflake_file_format" "ndjson_gz_file_format" {
  name     = "NDJSON_GZ_FILE_FORMAT"
  database = snowflake_database.this.name
  schema   = snowflake_schema.this.name
  compression = "AUTO"

  binary_format                  = "HEX"
  date_format                    = "AUTO"
  time_format                    = "AUTO"
  timestamp_format               = "AUTO"

  format_type = "JSON"
}

resource "snowflake_stage" "external_stage" {
  name     = var.stage_name
  database = snowflake_database.this.name
  schema   = snowflake_schema.this.name
  url      = "s3://${var.s3_bucket_name}/${var.s3_bucket_prefix}"

  credentials = "AWS_KEY_ID='${var.aws_key_id}' AWS_SECRET_KEY='${var.aws_secret_key}'"

  file_format = "FORMAT_NAME = ${snowflake_database.this.name}.${snowflake_schema.this.name}.${snowflake_file_format.ndjson_gz_file_format.name}"
}

resource "snowflake_table" "transactions_table" {
  database        = var.database_name
  schema          = var.schema_name
  name            = var.table_name
  change_tracking = true

  column {
    name = "data"
    type = "VARIANT"
  }

  depends_on = [
    snowflake_database.this,
    snowflake_schema.this
  ]
}

resource "snowflake_warehouse" "data_load_warehouse" {
  name     = "DATA_LOAD_WH"
  warehouse_size     = "LARGE"
  auto_suspend = 60
  auto_resume  = true
  initially_suspended = true
}

resource "snowflake_procedure" "data_load_sp" {
  name      = var.stored_proc_name
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
  name      = var.data_load_task_name
  database  = var.database_name
  schema    = var.schema_name
  warehouse = snowflake_warehouse.data_load_warehouse.name
  # This can be a CRON or an interval in minutes
  schedule        = var.data_load_task_interval
  user_task_timeout_ms = "3600000" # 1 hour
  comment         = "Load powerline data from external stage to table every hour."
  enabled = true

  sql_statement = "CALL ${var.database_name}.${var.schema_name}.${var.stored_proc_name}('${snowflake_warehouse.data_load_warehouse.name}')"

  depends_on = [
    snowflake_procedure.data_load_sp,
    snowflake_warehouse.data_load_warehouse
  ]
}
