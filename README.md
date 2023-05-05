# Importing data S3 to Snowflake #

This project consists of two terraform modules.  One module that helps you import from an S3 bucket into a "Stage" or "Raw" table in Snowflake (S3ToStageTable module).  The other module will help you import the data into your desire tables based on your own provided query (ImportFromStageTable module).

## S3ToStageTable Module ##
The inputs for the module are defined in the variables.tf file with their corresponding descriptions.  The outputs are defined in the outputs.tf file.  **This module assumes that the Database and Schema already exist, and it will fail if they don't**.

## ImportFromStageTable
The inputs of this module are defined in the variables.tf.  The same assumption is true about the Database and the schema, they must exist or the module will fail.

The **stage_table_name** variable refers to the table where the external data was loaded into.  It is assumed to have a JSON in one single Variant field.  If you are using the S3ToStageTable, you can leverage the output named **stage_table_name** or **stage_table_full_name** depending if you just need the simple name or the name including the database and schema.  

The **sql_import_query** variable is the SQL query that you will need to provide in order to populate the desired destination table.  A couple of things to keep in mind, these modules are not aware of your destination table so you must either create the table or make sure it exists.  Another thing to note is that in your query, which usually will be a MERGE query, your source will not be a table, but rather a Stream.  You don't need to worry about what the stream is, except that it gives you only new data that has been added to the stage table rather than all the data each time.  To provide the full name of the stream, you will need the database name, the schema name, a **prefix of "STREAM_"** and the name of the stage table.  Again, if you are using the S3ToStageTable, you can leverage the output named **stage_table_name** for this purpose.