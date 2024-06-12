#output "data_load_task_full_name" {
#  value       = "${snowflake_task.data_load_task.database}.${snowflake_task.data_load_task.schema}.${snowflake_task.data_load_task.name}"
#  description = "Full name (with database and schema) of the task which loads the S3 data into the transactions table."
#}

output "stage_table_name" {
  value       = snowflake_table.transactions_table.name
  description = "Transactions table name."
}

output "stage_table_full_name" {
  value       = "${var.database_name}.${var.schema_name}.${snowflake_table.transactions_table.name}"
  description = "Transactions table full name (including the database and schema)."
}