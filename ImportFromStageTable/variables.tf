# =============================================================================
# test_module — unified streaming-table importer.
#
# Supports THREE call styles:
#   1. LEGACY (backwards compatible): pass `name` (string) for an externally
#      owned table. The module creates ONLY the stream + task; the caller owns
#      the table. No TASK_META lineage. This is the original test_module
#      interface and keeps working unchanged.
#   2. MODULE-OWNED (v2): pass `columns` (+ `name`). The module creates the
#      table, prepends the TASK_META lineage ARRAY column, and TASK_META stamping
#      is mandatory.
#   3. EXTERNAL (v2): pass `existing_table` (a snowflake_table resource). The
#      module manages only the stream + task; TASK_META stamping is opt-in and
#      validated against the resource's declared columns.
#
# Mode is resolved from inputs:
#   columns != null        -> module-owned
#   existing_table != null -> external
#   otherwise              -> legacy (name-only)
# columns and existing_table are mutually exclusive.
# =============================================================================

# -----------------------------------------------------------------------------
# Identity
# -----------------------------------------------------------------------------

variable "name" {
  description = "Table/implementation base name, used in every mode the module manages naming. In LEGACY mode (caller owns the table) it drives the stream/task object names (STREAM_<name>, STREAM_TASK_<name>). In MODULE-OWNED mode (var.columns set) it is ALSO the name of the table the module creates. Ignored in EXTERNAL mode, where the name is derived from var.existing_table."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Table definition parameters (module-owned mode)
# These describe the target table that this module owns, in addition to the
# stream and task. They mirror the inputs of the snowflake_table resource.
# -----------------------------------------------------------------------------

variable "columns" {
  description = "Collection of columns for the target table, when this module OWNS the table. Mirrors the column blocks of the snowflake_table resource. Do NOT include the TASK_META lineage column — it is appended automatically. Mutually exclusive with existing_table; presence of columns selects module-owned mode."
  # Mirrors the full column block schema of the snowflake_table resource.
  # default.constant/expression/sequence are mutually exclusive, as are
  # default and identity (identity requires a numeric column type).
  type = list(object({
    name           = string
    type           = string
    nullable       = optional(bool, true)
    comment        = optional(string)
    collate        = optional(string)
    masking_policy = optional(string)
    default = optional(object({
      constant   = optional(string)
      expression = optional(string)
      sequence   = optional(string)
    }))
    identity = optional(object({
      start_num = optional(number)
      step_num  = optional(number)
    }))
  }))
  default = null

  validation {
    # At least one business column is required — the TASK_META lineage column is
    # appended automatically, but a table cannot be created from it alone.
    condition     = var.columns == null || length(coalesce(var.columns, [])) > 0
    error_message = "columns must define at least one column; the target table needs at least one business column besides the auto-appended TASK_META lineage column."
  }
}

variable "existing_table" {
  description = <<-DESC
    An externally-defined snowflake_table resource to target, when the table is
    managed OUTSIDE this module (pass the resource itself, e.g.
    `existing_table = snowflake_table.MY_TABLE`). The module then only manages
    the stream and task, and derives the table name (and STREAM_/STREAM_TASK_
    object names) from the resource — do NOT also set var.columns. Mutually
    exclusive with var.columns.

    In this mode the TASK_META lineage placeholders are OPTIONAL in
    sql_import_query: omit them for a plain old-style load, or use them if (and
    only if) the external table declares the lineage ARRAY column — the module
    validates this at plan time from the resource's column blocks.
  DESC
  # Callers pass the snowflake_table resource directly; this object type lists
  # only the attributes the module uses, so Terraform's type conversion strips
  # everything else at the module boundary — notably the deprecated
  # `primary_key` attribute, whose evaluation would otherwise raise
  # "Deprecated value used" warnings on every reference to this variable.
  type = object({
    name     = string
    database = string
    schema   = string
    column = optional(list(object({
      name     = string
      type     = string
      nullable = optional(bool)
      comment  = optional(string)
    })), [])
  })
  default = null
}

variable "table_comment" {
  description = "Comment for the target Snowflake table (module-owned mode)."
  type        = string
  default     = null
}

variable "change_tracking" {
  description = "Whether change tracking is enabled on the target table (module-owned mode)."
  type        = bool
  default     = false
}

variable "import_interval" {
  description = "Interval to run task to import the data."
  type        = string
  default     = "*/10 * * * * America/New_York"
}

variable "load_historical_data" {
  description = "If true, this will load all the existing data in the source table.  This is true by default."
  type        = bool
  default     = true
}

//These are read from the environment in the github action.

variable "database_name" {
  description = "The Snowflake database name. The database must exist or the module will fail."
  type        = string

  validation {
    condition     = length(trimspace(var.database_name)) > 0
    error_message = "database_name is required and must be a non-empty string."
  }
}

variable "schema_name" {
  description = "The Snowflake schema name. The schema must exist or the module will fail."
  type        = string

  validation {
    condition     = length(trimspace(var.schema_name)) > 0
    error_message = "schema_name is required and must be a non-empty string."
  }
}

variable "stage_table_full_name" {
  description = "The full name (including database and schema) of the Snowflake stage/source table where external data was loaded."
  type        = string

  validation {
    condition     = length(trimspace(var.stage_table_full_name)) > 0
    error_message = "stage_table_full_name is required and must be a non-empty string."
  }
}

variable "sql_import_query" {
  description = "Query to populate the desired table from the stream. This will most likely be a MERGE query. Must reference $$$STREAM$$$ (replaced with the stream name). When this module owns the table (var.columns), it must ALSO reference at least one of $$$TASK_META_NEW$$$ / $$$TASK_META_APPEND$$$ (the array-stamping expressions for the TASK_META column); with an external table (var.existing_table) those placeholders are optional, and allowed only if the table declares the lineage column; in legacy (name-only) mode the placeholders are NOT allowed."
  type        = string

  validation {
    condition     = length(trimspace(var.sql_import_query)) > 0
    error_message = "sql_import_query is required and must be a non-empty string."
  }

  validation {
    condition     = can(regex("[$][$][$]STREAM[$][$][$]", var.sql_import_query))
    error_message = "sql_import_query must reference the $$$STREAM$$$ placeholder so the module can inject the stream name."
  }

  # NOTE: the TASK_META placeholder requirement is mode-dependent (required when
  # the module owns the table, optional with existing_table, forbidden in legacy
  # name-only mode), so it is enforced as preconditions on the task resource in
  # main.tf, not here.

  validation {
    # The module wraps the query as a SINGLE statement. A trailing ';' (or
    # multiple statements) would break the task. Reject a trailing semicolon.
    condition     = !can(regex(";\\s*$", var.sql_import_query))
    error_message = "sql_import_query must be a single statement with NO trailing semicolon; the module manages statement termination itself."
  }
}

# -----------------------------------------------------------------------------
# Lineage / TASK_META stamping
# -----------------------------------------------------------------------------

variable "task_meta_column" {
  description = "Name of the ARRAY lineage column auto-prepended to the target table (module-owned mode). The caller stamps it via $$$TASK_META_NEW$$$ / $$$TASK_META_APPEND$$$ in sql_import_query."
  type        = string
  default     = "TASK_META"
}

variable "max_history" {
  description = "Maximum number of per-run metadata objects retained in the TASK_META array per record. When set, $$$TASK_META_APPEND$$$ keeps only the most recent N entries (sliding window, oldest dropped). Set to null for unbounded history (beware the 16MB row cap on hot records)."
  type        = number
  default     = 5

  validation {
    condition     = var.max_history == null || var.max_history >= 1
    error_message = "max_history must be null (unbounded) or a positive integer."
  }
}

variable "merge_target_alias" {
  description = "The alias the caller's MERGE uses for the target table (e.g. `MERGE INTO ... AS target`). Used by $$$TASK_META_APPEND$$$ to reference the existing array on the target row. Must match the alias in sql_import_query."
  type        = string
  default     = "target"
}

variable "stream_comment" {
  description = "Comment for the Snowflake stream resource."
  type        = string
  default     = "Stream for changes to the transactions source table"
}

variable "task_comment" {
  description = "Comment for the Snowflake task resource."
  type        = string
  default     = "Load data from external stage to data table on schedule."
}

variable "task_after" {
  description = "Optional list of predecessor task names that must complete before this task runs. Mutually exclusive with schedule."
  type        = list(string)
  default     = null
}

variable "user_task_timeout_ms" {
  description = "The number of milliseconds until the task times out. Defaults to 3600000 (1 hour)."
  type        = number
  default     = 3600000
}

variable "auto_retry_attempts" {
  description = "The number of times to retry a task that fails. Defaults to 0"
  type        = number
  default     = 0
}

variable "error_integration" {
  description = "Integration for Failed Task Notifications."
  type        = string
  default     = "SNS_NOTIFICATION" #TODO: This integration is hardcoded. It is defined in the Snowflake Adminsitration Project.
}
