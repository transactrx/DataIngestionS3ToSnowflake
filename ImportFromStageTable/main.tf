terraform {
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = ">= 0.99.0"
    }
  }
}

locals {
  # Three mutually exclusive modes (see variables.tf header):
  #   - module-owned : var.columns provided — the module creates the table and
  #     TASK_META stamping is mandatory.
  #   - external     : var.existing_table provided — the module manages only the
  #     stream/task and TASK_META stamping is opt-in.
  #   - legacy       : neither — the caller owns the table (original behavior),
  #     the module manages only the stream/task, and TASK_META is forbidden.
  is_module_owned = var.columns != null
  is_external     = var.existing_table != null
  is_legacy       = !local.is_module_owned && !local.is_external

  # The target table's name:
  #   external -> derived from the resource
  #   legacy / module-owned -> var.name (the single identity parameter)
  target_table_name = (
    local.is_external ? try(var.existing_table.name, null) : var.name
  )

  stream_name      = upper("stream_${local.target_table_name}")
  stream_name_full = "${var.database_name}.${var.schema_name}.${local.stream_name}"
  stream_task_name = upper("stream_task_${local.target_table_name}")

  task_meta_column = upper(var.task_meta_column)

  # Whether the caller's query opts into lineage stamping.
  is_query_uses_task_meta = (
    can(regex("[$][$][$]TASK_META_NEW[$][$][$]", var.sql_import_query)) ||
    can(regex("[$][$][$]TASK_META_APPEND[$][$][$]", var.sql_import_query))
  )

  # Whether the external table declares the lineage ARRAY column (plan-time
  # check against the resource's own column blocks; empty in non-external modes).
  is_existing_table_has_task_meta = anytrue([
    for c in try(var.existing_table.column, []) :
    upper(c.name) == local.task_meta_column && upper(c.type) == "ARRAY"
  ])

  # Lineage column auto-prepended as the FIRST column of the module-owned table
  # (invisible in var.columns). An ARRAY of meta objects stamped directly on the
  # row, so the full touch-history travels with the record. No external log table.
  audit_column = {
    name           = local.task_meta_column
    type           = "ARRAY"
    nullable       = true
    comment        = "Lineage history; array of per-run task metadata objects, NEWEST FIRST (index 0 = latest run). Capped at ${var.max_history == null ? "unbounded" : tostring(var.max_history)} entries."
    collate        = null
    masking_policy = null
    default        = null
    identity       = null
  }
  all_columns = concat([local.audit_column], coalesce(var.columns, []))
}

# Created only in module-owned mode; in external and legacy modes the caller's
# snowflake_table resource is the target and the module leaves it alone.
resource "snowflake_table" "this" {
  count = local.is_module_owned ? 1 : 0

  database        = var.database_name
  schema          = var.schema_name
  name            = local.target_table_name
  comment         = var.table_comment
  change_tracking = var.change_tracking

  dynamic "column" {
    for_each = local.all_columns
    content {
      name           = column.value.name
      type           = column.value.type
      nullable       = column.value.nullable
      comment        = column.value.comment
      collate        = column.value.collate
      masking_policy = column.value.masking_policy

      dynamic "default" {
        for_each = column.value.default == null ? [] : [column.value.default]
        content {
          constant   = default.value.constant
          expression = default.value.expression
          sequence   = default.value.sequence
        }
      }

      dynamic "identity" {
        for_each = column.value.identity == null ? [] : [column.value.identity]
        content {
          start_num = identity.value.start_num
          step_num  = identity.value.step_num
        }
      }
    }
  }

  lifecycle {
    # The lineage column is prepended automatically; callers must NOT also declare
    # it in var.columns, or table creation fails with a duplicate column.
    precondition {
      condition     = !contains([for c in coalesce(var.columns, []) : upper(c.name)], local.task_meta_column)
      error_message = "var.columns must not include the lineage column '${local.task_meta_column}' — it is appended automatically. Remove it from var.columns."
    }
  }
}

resource "snowflake_stream_on_table" "transactions_stream" {
  name     = local.stream_name
  database = var.database_name
  schema   = var.schema_name
  comment  = var.stream_comment

  table = var.stage_table_full_name

  append_only = "true"
  copy_grants = true

  show_initial_rows = var.load_historical_data

  lifecycle {
    ignore_changes = [
      show_initial_rows
    ]
  }
}

locals {
  # The per-run metadata object stamped onto each touched row. Every field is
  # computable inline (no SQLROWCOUNT/SQLID/STATUS), so no Scripting block is
  # needed — the data load IS the metadata write, in a single statement.
  #
  # NOTE: these SYSTEM$ functions only return meaningful values inside a running
  # task. RUN_GROUP_ID is shared by all tasks in one task-graph run; combine it
  # with TASK_NAME if you need to distinguish chained tasks within a run.
  meta_object = trimspace(<<-EXPR
    OBJECT_CONSTRUCT(
      'RUN_GROUP_ID', SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'),
      'ROOT_TASK_NAME', SYSTEM$TASK_RUNTIME_INFO('CURRENT_ROOT_TASK_NAME'),
      'ROOT_TASK_UUID', SYSTEM$TASK_RUNTIME_INFO('CURRENT_ROOT_TASK_UUID'),
      'TASK_NAME', SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_NAME'),
      'SCHEDULED_TIME', SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_ORIGINAL_SCHEDULED_TIMESTAMP'),
      'RUN_TIME', CURRENT_TIMESTAMP()
    )
  EXPR
  )

  # The existing array on the target row, null-safe for historical rows that
  # predate the column / were bulk-loaded with no array.
  target_col = "${var.merge_target_alias}.${local.task_meta_column}"
  prev_array = "COALESCE(${local.target_col}, ARRAY_CONSTRUCT())"

  # $$$TASK_META_NEW$$$ — seed a one-element array (INSERT / not-matched branch).
  new_expr = "ARRAY_CONSTRUCT(${local.meta_object})"

  # $$$TASK_META_APPEND$$$ — prepend to the existing array so the NEWEST run is
  # always at index 0 (UPDATE / matched branch). When max_history = N, first slice
  # the existing array to its first N-1 entries (the most recent N-1) so the result
  # is exactly N after the prepend (sliding window, oldest at the tail dropped).
  # ARRAY_SLICE(arr, 0, N-1) is naturally safe for arrays shorter than N-1.
  append_expr = var.max_history == null ? (
    "ARRAY_PREPEND(${local.prev_array}, ${local.meta_object})"
    ) : (
    "ARRAY_PREPEND(ARRAY_SLICE(${local.prev_array}, 0, ${var.max_history - 1}), ${local.meta_object})"
  )

  # User statement with all placeholders substituted:
  #   $$$STREAM$$$            -> fully-qualified stream name
  #   $$$TASK_META_NEW$$$     -> ARRAY_CONSTRUCT(<meta object>)
  #   $$$TASK_META_APPEND$$$  -> ARRAY_PREPEND(... <meta object>)  (newest at index 0)
  user_statement = replace(
    replace(
      replace(
        var.sql_import_query,
      "$$$STREAM$$$", local.stream_name_full),
    "$$$TASK_META_APPEND$$$", local.append_expr),
    "$$$TASK_META_NEW$$$", local.new_expr
  )
}

resource "snowflake_task" "stream_task" {
  name                     = local.stream_task_name
  database                 = var.database_name
  schema                   = var.schema_name
  task_auto_retry_attempts = var.task_after == null ? var.auto_retry_attempts : null
  error_integration        = var.task_after == null ? var.error_integration : null
  user_task_timeout_ms     = var.user_task_timeout_ms
  comment                  = var.task_comment
  started                  = true

  allow_overlapping_execution = false

  after = var.task_after
  dynamic "schedule" {
    # Schedule is mutually exclusive with after
    for_each = var.task_after == null ? [1] : []
    content {
      using_cron = var.import_interval
    }
  }

  # A plain single statement — in v2 modes the load both writes the data and
  # stamps the TASK_META array; in legacy mode it is the caller's query verbatim
  # (only $$$STREAM$$$ substituted). No Scripting block, no separate logging.
  sql_statement = local.user_statement

  when = "system$stream_has_data('${local.stream_name_full}')"

  lifecycle {
    # columns and existing_table are mutually exclusive — they select different
    # modes and the table name cannot be derived from both.
    precondition {
      condition     = !(local.is_module_owned && local.is_external)
      error_message = "var.columns (module-owned mode) and var.existing_table (external mode) are mutually exclusive — provide at most one. For a legacy externally-owned table, pass only var.name."
    }

    # Every mode needs a resolvable base name for the table/stream/task.
    precondition {
      condition     = length(trimspace(coalesce(local.target_table_name, ""))) > 0
      error_message = "Could not determine the table/stream/task base name. Set var.name (legacy or module-owned mode), or var.existing_table (external mode)."
    }

    # Module-owned mode guarantees the TASK_META column exists, so the query
    # must stamp it. (In external mode stamping is optional; in legacy mode it
    # is forbidden.)
    precondition {
      condition     = !local.is_module_owned || local.is_query_uses_task_meta
      error_message = "sql_import_query must reference at least one of $$$TASK_META_NEW$$$ (INSERT branch: seeds the array) or $$$TASK_META_APPEND$$$ (UPDATE branch: appends to the array) so each touched row is stamped with its lineage metadata."
    }

    # External mode: the query may only use the TASK_META placeholders if the
    # external table actually declares the lineage ARRAY column — otherwise the
    # substituted SQL would reference a missing column and fail at task runtime.
    precondition {
      condition     = !local.is_external || !local.is_query_uses_task_meta || local.is_existing_table_has_task_meta
      error_message = "sql_import_query uses the $$$TASK_META_*$$$ placeholders, but var.existing_table does not declare a '${local.task_meta_column}' column of type ARRAY. Add the column to the external table, or remove the placeholders from the query."
    }

    # Legacy (name-only) mode: TASK_META stamping is not supported — the module
    # does not manage the table and cannot guarantee the lineage column exists.
    precondition {
      condition     = !local.is_legacy || !local.is_query_uses_task_meta
      error_message = "sql_import_query uses the $$$TASK_META_*$$$ placeholders, but neither var.columns (module-owned) nor var.existing_table (external) was provided. TASK_META lineage is not available in legacy name-only mode — remove the placeholders, or switch to one of the v2 modes."
    }

    # External mode: the table must live in the same database/schema the module
    # is told to build the stream/task in — otherwise the stream/task land in
    # one schema while the MERGE targets a table in another.
    precondition {
      condition = !local.is_external || (
        upper(try(var.existing_table.database, "")) == upper(var.database_name) &&
        upper(try(var.existing_table.schema, "")) == upper(var.schema_name)
      )
      error_message = "var.existing_table lives in '${try(var.existing_table.database, "?")}.${try(var.existing_table.schema, "?")}' but the module was given database_name/schema_name '${var.database_name}.${var.schema_name}'. These must match — the stream and task are created alongside the target table."
    }
  }

  # The task references the target table and stream by literal name (not by
  # resource attribute), so Terraform cannot infer ordering from sql_import_query.
  # Make it explicit so the stream (and, in module-owned mode, the table) exist
  # before the task is created and started. In external mode, ordering relative
  # to the table comes from the caller passing the resource via var.existing_table
  # (the module input depends on it). In legacy mode the caller owns the table
  # entirely and there is no module-level dependency on it.
  depends_on = [
    snowflake_table.this,
    snowflake_stream_on_table.transactions_stream,
  ]
}
