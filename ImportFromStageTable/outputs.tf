output "stream_name" {
  description = "Name of the Snowflake stream created"
  value       = snowflake_stream_on_table.transactions_stream.fully_qualified_name
}

output "task_name" {
  description = "Name of the Snowflake task created"
  value       = snowflake_task.stream_task.fully_qualified_name
}

output "table" {
  description = <<-EOT
    The module-owned snowflake_table resource, exposing database, schema, name,
    and column attributes for downstream consumers (e.g. building shared views).
    Non-null only in module-owned mode (var.columns set); null in legacy and
    external modes where the module does not own the table.
  EOT
  value       = one(snowflake_table.this)
}
