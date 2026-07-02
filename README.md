# Importing data S3 to Snowflake #

This project consists of two terraform modules.  One module that helps you import from an S3 bucket into a "Stage" or 
"Raw" table in Snowflake (S3ToStageTable module).  The other module will help you import the data into your desired 
tables based on your own provided query (ImportFromStageTable module).

## S3ToStageTable Module ##
The inputs for the module are defined in the variables.tf file with their corresponding descriptions.  The outputs are 
defined in the outputs.tf file.  **This module assumes that the Database and Schema already exist, and it will fail if 
they don't**.

## ImportFromStageTable

The inputs of this module are defined in the variables.tf.  The same assumption is true about the Database and the 
schema, they must exist or the module will fail.

The **stage_table_full_name** variable refers to the table where the external data was loaded into.  It is assumed to 
have a JSON in one single Variant field.  If you are using the S3ToStageTable, you can leverage the output named 
**stage_table_name** or **stage_table_full_name** depending if you just need the simple name or the name including the 
database and schema.

The **sql_import_query** variable is the SQL query that you will need to provide in order to populate the desired 
destination table.  A couple of things to keep in mind: your source will not be a table, but rather a Stream.  You 
don't need to worry about what the stream is, except that it gives you only new data that has been added to the stage 
table rather than all the data each time.  In your query, to refer to the stream just use the placeholder 
`$$$STREAM$$$`.  The query is wrapped as a **single statement** — do not include a trailing semicolon, and it must 
reference `$$$STREAM$$$`.

### The three modes

The module supports three call styles. **The mode is selected automatically from the inputs you pass — there is no 
mode flag.**

| Mode | You pass | Module creates | TASK_META lineage |
|------|----------|----------------|-------------------|
| **Legacy** | `name` only | stream + task (you own the table) | Not available |
| **Module-owned** | `columns` (+ `name`) | table + stream + task | Required |
| **External** | `existing_table` | stream + task (you own the table) | Optional |

`columns` and `existing_table` are mutually exclusive — providing both fails at plan time.

**Which mode should I use?**

- **New implementations → Module-owned.** This is the preferred path going forward. Let the module own the table so 
  it can manage the full lifecycle — table, stream, and task — and guarantee the `TASK_META` lineage column is present 
  and stamped from day one.
- **Existing legacy implementations → External.** This mode exists to make it easy to transition a table you already 
  own onto TASK_META: keep your current table definition in place, add a `TASK_META ARRAY` column, point the module at 
  the resource via `existing_table`, and add the lineage placeholders to your query. No need to migrate the table 
  under module ownership.
- **Legacy** remains for backwards compatibility only; prefer External when you want lineage without changing table 
  ownership.

#### What is TASK_META?

TASK_META is an `ARRAY` column that records a compact, per-record history of the tasks that loaded it — **newest 
first** (index 0 is the latest run). Each entry is an object with the run/task identifiers, the scheduled time, and 
the run time. It lets you answer "how did this record get here, and which run loaded it?" directly on the row, instead 
of reconstructing it from task history and timestamps.

It is written during the normal load (no separate audit table, no Scripting block) using two placeholders in your 
`sql_import_query`:

- `$$$TASK_META_NEW$$$` — use in the **INSERT / NOT MATCHED** branch; seeds a one-element array for a brand-new row.
- `$$$TASK_META_APPEND$$$` — use in the **UPDATE / MATCHED** branch; prepends the current run to the existing array.

By default only the most recent **5** runs are retained per row (`max_history`, configurable; set to `null` for 
unbounded — beware the 16 MB row cap on hot records). When you use `$$$TASK_META_APPEND$$$`, make sure 
`merge_target_alias` matches the alias your MERGE uses for the target table (default `target`).

#### Query placeholders (macros)

The module rewrites your `sql_import_query` before creating the task, substituting these `$$$...$$$` macros. Use them 
verbatim — the module fills in the real Snowflake objects/expressions.

| Macro | Required? | Expands to |
|-------|-----------|------------|
| `$$$STREAM$$$` | **Always** | The fully-qualified name of the stream the module manages (`DB.SCHEMA.STREAM_<name>`). |
| `$$$TASK_META_NEW$$$` | Mode-dependent | `ARRAY_CONSTRUCT(<run-metadata object>)` — a fresh one-element lineage array. |
| `$$$TASK_META_APPEND$$$` | Mode-dependent | `ARRAY_PREPEND(<existing array, sliced to max_history-1>, <run-metadata object>)` — newest entry first. |

**`$$$STREAM$$$`** is the heart of the import. Instead of reading the stage table directly, your query reads from a 
Snowflake **stream** on that table, which the module creates and manages for you. A stream is a change-tracking object 
that exposes only the rows added since the task last consumed it — so each run processes just the new data, not the 
entire table every time. You don't manage the stream's name or lifecycle; you simply write `FROM $$$STREAM$$$` 
wherever you'd normally read the source, and the module injects the correct fully-qualified stream name at plan time. 
The query is required to reference `$$$STREAM$$$` at least once (validated in `variables.tf`).

The `$$$TASK_META_*$$$` macros are required in Module-owned mode, optional in External mode (only if the table 
declares the `TASK_META ARRAY` column), and forbidden in Legacy mode — see the per-mode sections below.

---

### Mode 1 — Legacy (you own the table)

The original interface. You create and manage the destination table yourself; the module builds only the stream and 
task. TASK_META is **not** available, and the `$$$TASK_META_*$$$` placeholders are rejected.

```hcl
module "import_customers" {
  source = "./ImportFromStageTable"

  name                  = "CUSTOMERS"
  database_name         = "ANALYTICS"
  schema_name           = "PUBLIC"
  stage_table_full_name = "ANALYTICS.PUBLIC.STAGE_CUSTOMERS"

  sql_import_query = <<-SQL
    MERGE INTO ANALYTICS.PUBLIC.CUSTOMERS AS target
    USING (
      SELECT
        v:id::NUMBER        AS id,
        v:name::STRING      AS name,
        v:email::STRING     AS email
      FROM $$$STREAM$$$
    ) AS source
    ON target.id = source.id
    WHEN MATCHED THEN UPDATE SET
      target.name  = source.name,
      target.email = source.email
    WHEN NOT MATCHED THEN INSERT (id, name, email)
      VALUES (source.id, source.name, source.email)
  SQL
}
```

---

### Mode 2 — Module-owned (the module builds the table)

**This is the preferred mode for brand-new implementations.** Pass `columns` and the module creates the table for you, automatically prepending the `TASK_META` lineage column as 
the first column. **Do not** include `TASK_META` in `columns` — it is added for you, and declaring it yourself fails 
with a duplicate-column error. Because the table is guaranteed to have the lineage column, the query **must** stamp it.

This example is taken from a real reference-data export
(`ras-datawarehouse/ras-datawarehouse-reference-data/dbExport_datadic_RULEDATA_COPAY_VENDOR.tf`).
Note that it consumes the module straight from the git source, drives names through `locals`,
dedups the change stream, and handles soft-deletes via an `OPERATIONTYPE` — patterns you will
reuse across most module-owned tables.

```hcl
locals {
  ruledata_copay_vendor_table = "RULEDATA_COPAY_VENDOR"
}

module "RULEDATA_COPAY_VENDOR" {
  source        = "git::https://github.com/transactrx/DataIngestionS3ToSnowflake.git//ImportFromStageTable?ref=main"
  database_name = local.database_name
  schema_name   = local.data_dictionary_schema_name
  name          = local.ruledata_copay_vendor_table
  table_comment = "copay_vendor data exported from external dbexport database."

  # Module owns the table. Do NOT declare the TASK_META lineage column —
  # the module auto-prepends it as the first column.
  columns = [
    { name = "VERSION", type = "NUMBER(38,0)" },
    { name = "ID", type = "STRING" },
    { name = "NAME", type = "STRING" },
    { name = "DESCRIPTION", type = "STRING" },
    { name = "ACTION", type = "STRING" },
    { name = "RECORD_STATUS", type = "STRING" },
    { name = "START", type = "STRING" },
    { name = "STOP", type = "STRING" },
    # ... remaining source columns ...
  ]

  sql_import_query = <<SQL
    MERGE INTO ${local.database_name}.${local.data_dictionary_schema_name}.${local.ruledata_copay_vendor_table} AS target
    USING (
      WITH ranked_data AS (
        SELECT
          ROW_NUMBER() OVER (
            PARTITION BY DATA:eventPayload:id::varchar
            ORDER BY DATA:eventPayload:db_export_record_version::numeric DESC
          ) AS rnk,
          DATA:eventPayload:db_export_record_version::numeric AS VERSION,
          DATA:eventPayload:id::varchar AS ID,
          DATA:eventPayload:name::varchar AS NAME,
          DATA:eventPayload:description::varchar AS DESCRIPTION,
          DATA:eventPayload:action::varchar AS ACTION,
          DATA:eventPayload:record_status::varchar AS RECORD_STATUS,
          DATA:eventPayload:start::varchar AS "START",
          DATA:eventPayload:stop::varchar AS "STOP",
          COALESCE(DATA:operationType::varchar, 'UPSERT') AS OPERATIONTYPE
        FROM $$$STREAM$$$ t
        WHERE t.DATA:eventType::varchar = 'dbexport-rule-data-copay-vendor'
      )
      SELECT * FROM ranked_data WHERE rnk = 1
    ) AS source
    ON target.ID = source.ID
    WHEN MATCHED AND source.OPERATIONTYPE = 'DELETE' THEN
      DELETE
    WHEN MATCHED AND source.OPERATIONTYPE != 'DELETE' THEN UPDATE SET
      VERSION = source.VERSION,
      NAME = source.NAME,
      DESCRIPTION = source.DESCRIPTION,
      ACTION = source.ACTION,
      RECORD_STATUS = source.RECORD_STATUS,
      "START" = source."START",
      "STOP" = source."STOP",
      TASK_META = $$$TASK_META_APPEND$$$
    WHEN NOT MATCHED AND source.OPERATIONTYPE != 'DELETE' THEN INSERT (
      VERSION, ID, NAME, DESCRIPTION, ACTION, RECORD_STATUS, "START", "STOP", TASK_META
    ) VALUES (
      source.VERSION, source.ID, source.NAME, source.DESCRIPTION, source.ACTION,
      source.RECORD_STATUS, source."START", source."STOP", $$$TASK_META_NEW$$$
    )
  SQL

  merge_target_alias    = "target"
  load_historical_data  = true
  stage_table_full_name = local.events_stage_table_full_name
  import_interval       = "25 * * * * UTC"
}
```

---

### Mode 3 — External (you own the table, module manages stream + task)

Pass the `snowflake_table` resource itself via `existing_table`. The module manages only the stream and task and 
derives all naming from the resource — do **not** also set `name` or `columns`. The table must live in the same 
`database_name` / `schema_name` you give the module.

TASK_META here is **opt-in**: add a `TASK_META ARRAY` column to your own table to use the placeholders, or omit both 
the column and the placeholders for a plain load. The module validates this pairing at plan time.

This mode exists to **easily transition existing legacy implementations onto TASK_META**: keep the table you already 
own in your own Terraform, add the `TASK_META ARRAY` column, point the module at it, and the module takes over the 
stream and task. For brand-new implementations, prefer Module-owned (Mode 2) instead.

```hcl
resource "snowflake_table" "invoices" {
  database = "ANALYTICS"
  schema   = "PUBLIC"
  name     = "INVOICES"

  column {
    name = "ID"
    type = "NUMBER"
  }
  column {
    name = "TOTAL"
    type = "NUMBER(12,2)"
  }

  # Add this column to opt into TASK_META lineage. Omit it for a plain load.
  column {
    name = "TASK_META"
    type = "ARRAY"
  }
}

module "import_invoices" {
  source = "./ImportFromStageTable"

  existing_table = snowflake_table.invoices

  database_name         = "ANALYTICS"
  schema_name           = "PUBLIC"
  stage_table_full_name = "ANALYTICS.PUBLIC.STAGE_INVOICES"

  sql_import_query = <<-SQL
    MERGE INTO ANALYTICS.PUBLIC.INVOICES AS target
    USING (
      SELECT
        v:id::NUMBER     AS id,
        v:total::NUMBER  AS total
      FROM $$$STREAM$$$
    ) AS source
    ON target.id = source.id
    WHEN MATCHED THEN UPDATE SET
      target.total     = source.total,
      target.TASK_META = $$$TASK_META_APPEND$$$
    WHEN NOT MATCHED THEN INSERT (id, total, TASK_META)
      VALUES (source.id, source.total, $$$TASK_META_NEW$$$)
  SQL
}
```

To run this mode **without** lineage, drop the `TASK_META` column from the table and remove the `$$$TASK_META_*$$$` 
placeholders from the query.

### Module inputs

All inputs are defined with their descriptions in `variables.tf`; this table summarizes them and notes which mode 
each applies to.

| Input | Type | Default | Applies to | Description |
|-------|------|---------|------------|-------------|
| `database_name` | string | _(required)_ | all | Snowflake database. Must already exist. |
| `schema_name` | string | _(required)_ | all | Snowflake schema. Must already exist. |
| `stage_table_full_name` | string | _(required)_ | all | Fully-qualified stage/source table the stream is built on. |
| `sql_import_query` | string | _(required)_ | all | The load query. Must reference `$$$STREAM$$$`, single statement, no trailing semicolon. |
| `name` | string | `null` | Legacy, Module-owned | Base name for the stream/task; also the table name in Module-owned mode. Ignored in External mode. |
| `columns` | list(object) | `null` | Module-owned | Column definitions for the table the module builds. Do **not** include `TASK_META`. Selects Module-owned mode. |
| `existing_table` | object | `null` | External | The `snowflake_table` resource to target. Selects External mode. Mutually exclusive with `columns`. |
| `table_comment` | string | `null` | Module-owned | Comment on the table the module creates. |
| `change_tracking` | bool | `false` | Module-owned | Enables change tracking on the table the module creates. |
| `max_history` | number | `5` | Module-owned, External | **History size** — max per-run entries kept in the `TASK_META` array per row (sliding window, oldest dropped). `null` = unbounded (watch the 16 MB row cap). |
| `task_meta_column` | string | `"TASK_META"` | Module-owned, External | Name of the lineage ARRAY column the macros stamp (and that the module prepends in Module-owned mode). |
| `merge_target_alias` | string | `"target"` | Module-owned, External | The alias your MERGE uses for the target table; `$$$TASK_META_APPEND$$$` references the existing array through it. |
| `import_interval` | string | `*/10 * * * * America/New_York` | all | Cron schedule for the task. Mutually exclusive with `task_after`. |
| `task_after` | list(string) | `null` | all | Predecessor task names; makes this a child task instead of scheduled. Mutually exclusive with `import_interval`. |
| `load_historical_data` | bool | `true` | all | If true, the stream includes the rows already in the stage table on first run. |
| `user_task_timeout_ms` | number | `3600000` | all | Task timeout in milliseconds (default 1 hour). |
| `auto_retry_attempts` | number | `0` | all | Retries for a failed task (scheduled tasks only). |
| `error_integration` | string | `SNS_NOTIFICATION` | all | Notification integration for failed tasks (scheduled tasks only). |
| `stream_comment` | string | _(see variables.tf)_ | all | Comment on the stream resource. |
| `task_comment` | string | _(see variables.tf)_ | all | Comment on the task resource. |

### Outputs

Both `stream_name` and `task_name` are returned as fully-qualified Snowflake names (see `outputs.tf`).
