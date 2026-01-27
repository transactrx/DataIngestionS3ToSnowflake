output "stream_name" {
  description = "Name of the Snowflake stream created"
  value       = snowflake_stream_on_table.transactions_stream.fully_qualified_name
}

output "task_name" {
  description = "Name of the Snowflake task created"
  value       = snowflake_task.stream_task.fully_qualified_name
}
