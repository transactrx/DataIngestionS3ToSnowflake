output "warehouse_name" {
  value       = snowflake_warehouse.data_load_warehouse.name
  description = "Snowflake warehouse name."
}

output "data_load_task_name" {
  value       = "${snowflake_task.data_load_task.database}.${snowflake_task.data_load_task.schema}.${snowflake_task.data_load_task.name}"
  description = "Task which loads the S3 data into the transactions table."
}

output "raw_table_name" {
  value       = "${snowflake_task.data_load_task.database}.${snowflake_task.data_load_task.schema}.${snowflake_table.transactions_table.name}"
  description = "Transactions table name."
}
