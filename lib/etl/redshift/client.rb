require 'tempfile'
require 'aws-sdk'
require 'csv'
require 'sequel'
require 'odbc'
require 'mixins/cached_logger'
require 'pathname'
require 'fileutils'

module ETL::Redshift
  # when the odbc driver is setup in chef this is the driver's name
  REDSHIFT_ODBC_DRIVER_NAME = 'Amazon Redshift (x64)'.freeze

  # Class that contains shared logic for accessing Redshift.
  class Client
    include ETL::CachedLogger
    attr_accessor :db, :region, :iam_role, :bucket, :delimiter, :row_columns_symbolized, :cache_table_schema_lookup, :tmp_dir

    # when odbc driver is fully working the use redshift driver can
    # default to true
    def initialize(conn_params = {}, aws_params = {})
      @region = aws_params.fetch(:region)
      @bucket = aws_params.fetch(:s3_bucket)
      @iam_role = aws_params.fetch(:role_arn)
      @delimiter = "\u0001"

      # note the host is never specified as its part of the dsn name and for now that is hardcoded as 'MyRealRedshift'
      password = conn_params.fetch(:password)
      dsn = conn_params.fetch(:dsn, 'MyRealRedshift')
      user = conn_params.fetch(:username, nil) || conn_params.fetch(:user, '')
      raise 'No user was provided in the connection parameters' if user.empty?
      @odbc_conn_params = { database: dsn, password: password, user: user }
      ObjectSpace.define_finalizer(self, proc { disconnect })
      @row_columns_symbolized = true
      @cache_table_schema_lookup = true
      @cached_table_schemas = {}
      @tmp_dir = conn_params.fetch(:tmp_dir, '/tmp')
    end

    def disconnect
      @db.disconnect unless @db.nil?
    end

    def db
      @db ||= begin
                  Sequel.odbc(@odbc_conn_params)
              end
    end

    def execute_ddl(sql)
      log.debug("execute_ddl SQL: '#{sql}'")
      db.execute_ddl(sql)
    end

    def execute_dui(sql)
      log.debug("execute_dui SQL: '#{sql}'")
      db.execute_dui(sql)
    end

    def execute_insert(sql)
      log.debug("execute insert: SQL: '#{sql}'")
      db.execute_insert(sql)
    end

    def fetch(sql)
      log.debug("fetch SQL: '#{sql}'")
      db.fetch(sql)
    end

    def execute(sql)
      log.debug("execute SQL: '#{sql}'")
      db.execute(sql)
    end

    def drop_table(schema_name, table_name)
      sql = "DROP TABLE IF EXISTS #{schema_name}.#{table_name};"
      execute_ddl(sql)
    end

    def create_table(table)
      sql = table.create_table_sql
      execute_ddl(sql)
    end

    def table_schema(schema_name, table_name)
      cached_table = nil
      full_name = "#{schema_name}.#{table_name}"
      cached_table = @cached_table_schemas[full_name] if @cache_table_schema_lookup
      return cached_table unless cached_table.nil?
      execute("set search_path to #{schema_name}")
      information_schema_columns_sql = <<SQL
select * from pg_table_def
left Join information_schema.columns as i on i.table_schema = pg_table_def.schemaname and i.table_name = pg_table_def.tablename and i.column_name = pg_table_def."column"
where tablename = '#{table_name}' and schemaname = '#{schema_name}'
SQL
      columns_info = []
      fetch(information_schema_columns_sql).each { |v| columns_info << v }
      table_constraint_info_sql = <<SQL
SELECT conkey, pg_namespace.nspname
FROM pg_constraint
LEFT JOIN pg_namespace On pg_constraint.connamespace = pg_namespace.OID
LEFT JOIN pg_class ON pg_constraint.connamespace = pg_class.relnamespace
WHERE contype = 'p' and conrelid = (
    SELECT oid FROM pg_class WHERE relname = '#{table_name}' and relnamespace = pg_namespace.OID)
SQL
      pk_ordinals = []
      values = []
      fetch(table_constraint_info_sql).each do |v|
        values << v
      end
      if !values.nil? && !values.empty?
        con_key = values[0].fetch(:conkey)
        split_keys = con_key.tr('{}', '').split(',')
        split_keys.each do |v|
          pk_ordinals << v.to_i
        end
      end

      fks_sql = <<SQL
SELECT * FROM (
  SELECT
    o.conname AS constraint_name,
    (SELECT nspname FROM pg_namespace WHERE oid=m.relnamespace) AS source_schema,
    m.relname AS source_table,
    (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = m.oid AND a.attnum = o.conkey[1] AND a.attisdropped = false) AS source_column,
    (SELECT nspname FROM pg_namespace WHERE oid=f.relnamespace) AS target_schema,
    f.relname AS target_table,
    (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = f.oid AND a.attnum = o.confkey[1] AND a.attisdropped = false) AS target_column
  FROM
    pg_constraint o LEFT JOIN pg_class c ON c.oid = o.conrelid
    LEFT JOIN pg_class f ON f.oid = o.confrelid LEFT JOIN pg_class m ON m.oid = o.conrelid
  WHERE
    o.contype = 'f' AND m.relname = '#{table_name}' AND o.conrelid IN (SELECT oid FROM pg_class c WHERE c.relkind = 'r')
) where source_schema = '#{schema_name}'
SQL
      fks = fetch(fks_sql).map
      table = ::ETL::Redshift::Table.from_schema(table_name, columns_info, pk_ordinals, fks)
      table.schema = schema_name
      @cached_table_schemas[table.name] = table if @cache_table_schema_lookup
      table
    end

    def columns(schema_name, table_name)
      sql = <<SQL
      SELECT "column", type FROM pg_table_def WHERE tablename = '#{table_name}' and schemaname = '#{schema_name}'
SQL
      fetch(sql)
    end

    def count_row_by_s3(destination)
      sql = <<SQL
        SELECT c.lines_scanned FROM stl_load_commits c, stl_query q WHERE filename LIKE 's3://#{destination}%'
        AND c.query = q.query AND trim(q.querytxt) NOT LIKE 'COPY ANALYZE%'
SQL
      results = fetch(sql)
      loaded_rows = 0
      results.each { |result| loaded_rows += result[:lines_scanned].to_i || 0 }
      loaded_rows
    end

    def unload_to_s3(query, destination)
      sql = <<SQL
        UNLOAD ('#{query}') TO 's3://#{destination}'
        IAM_ROLE '#{@iam_role}'
        DELIMITER '#{@delimiter}'
SQL
      execute(sql)
    end

    def copy_from_s3(table_name, destination)
      sql = <<SQL
        COPY #{table_name}
        FROM 's3://#{destination}'
        IAM_ROLE '#{@iam_role}'
        TIMEFORMAT AS 'auto'
        DATEFORMAT AS 'auto'
        DELIMITER '#{@delimiter}'
        REGION '#{@region}'
SQL
      execute(sql)
    end

    def delete_object_from_s3(bucket, prefix, _session_name)
      s3 = Aws::S3::Client.new(region: @region)
      resp = s3.list_objects(bucket: bucket)
      keys = resp[:contents].select { |content| content.key.start_with? prefix }.map(&:key)

      keys.each { |key| s3.delete_object(bucket: bucket, key: key) }
    end

    def temp_file(table_name)
      # creating a daily file path so if the disk gets full its
      # easy to kiil all the days except the current.
      date_path = DateTime.now.strftime("%Y_%m_%d")
      dir_path = "#{@tmp_dir}/redshift/#{date_path}"
      FileUtils.makedirs(dir_path) unless Dir.exists?(dir_path)
      temp_file = "#{dir_path}/#{table_name}_#{SecureRandom.hex(5)}"
      FileUtils.touch(temp_file)
      temp_file
    end

    # Upserts rows into the destintation tables based on rows
    # provided by the reader.
    def upsert_rows(reader, table_schemas_lookup, row_transformer, validator = nil)
      add_rows(reader, table_schemas_lookup, row_transformer, validator,  AddNewData.new("upsert"))
    end

    # Appends rows into the destintation tables based on rows
    # provided by the reader.
    def append_rows(reader, table_schemas_lookup, row_transformer, validator = nil)
      add_rows(reader, table_schemas_lookup, row_transformer, validator,  AddNewData.new("append")) 
    end

    # adds rows into the destintation tables based on rows
    # provided by the reader and their add data type.
    def add_rows(reader, table_schemas_lookup, row_transformer, validator = nil, add_new_data)
      tmp_session = table_schemas_lookup.keys.join('_') + SecureRandom.hex(5)

      # Remove new lines ensures that all row values have newlines removed.
      remove_new_lines = ::ETL::Transform::RemoveNewlines.new
      row_transformers = [remove_new_lines]
      row_transformers << row_transformer unless row_transformer.nil?

      csv_files = {}
      csv_file_paths = {}
      file_uploaded = {}
      rows_processed_map = {}
      table_schemas_lookup.keys.each do |t|
        csv_file_paths[t] = temp_file(t)
        csv_files[t] = ::CSV.open(csv_file_paths[t], 'w', col_sep: @delimiter)
        rows_processed_map[t] = 0
      end

      begin
        reader.each_row do |row|
          values_lookup = transform_row(table_schemas_lookup, row_transformers, row)
          next if values_lookup.is_a? SkipRow

          values_lookup.each_pair do |table_name, row_arrays|
            tschema = table_schemas_lookup[table_name]
            row_arrays.each do |values_arr|
              csv_row = CSV::Row.new(tschema.columns.keys, values_arr)
              csv_files[table_name].add_row(csv_row)
              rows_processed_map[table_name] += 1
            end
          end
        end
      ensure
        table_schemas_lookup.each_pair do |t, tschema|
          if rows_processed_map[t] == 0
            log.debug("table #{t} has zero rows no upload required")
            next
          end

          csv_files[t].close
          local_file_path = csv_file_paths[t]
          s3_file_name = File.basename(local_file_path)
          s3_path = "#{@bucket}/#{s3_file_name}"

          tmp_table = create_staging_table(tschema.schema, t)
          s3_resource = Aws::S3::Resource.new(region: @region)
          s3_resource.bucket(@bucket).object(s3_file_name).upload_file(local_file_path)
          file_uploaded[t] = true

          # Delete the local file to not fill up that machine.
          ::File.delete(local_file_path)
          full_table = "#{tschema.schema}.#{t}"
          copy_from_s3(tmp_table, s3_path)
          where_id_join = ''
          tschema.primary_key.each do |pk|
            if where_id_join == ''
              where_id_join = "where #{full_table}.#{pk} = #{tmp_table}.#{pk}"
            else
              where_id_join = "#{where_id_join} and #{full_table}.#{pk} = #{tmp_table}.#{pk}"
            end
          end

          validator.validate(t, tmp_table, tschema) if validator
          add_sql = add_new_data.build_sql(tmp_table, full_table, { where_id_join: where_id_join })
          execute(add_sql)
          if file_uploaded[t]
            s3_resource.bucket(@bucket).object(s3_file_name).delete()
          end
        end
      end
      highest_num_rows_processed = 0

      # might need to do something different but doing this for now.
      rows_processed_map.each_pair do |_key, value|
        highest_num_rows_processed = value if highest_num_rows_processed < value
      end
      highest_num_rows_processed
    end

    def table_exists?(schema, table_name)
      sql = "SELECT count(*)  FROM pg_tables where schemaname = '#{schema}' and tablename = '#{table_name}'"
      result = fetch(sql).first
      return result[:count] == 1
    end

    def create_staging_table(final_table_schema, final_table_name)
      tmp_table_name = final_table_name + SecureRandom.hex(5)
      # create temp table to add data to.
      tmp_table = ::ETL::Redshift::Table.new(tmp_table_name, temp: true, like: "#{final_table_schema}.#{final_table_name}")
      create_table(tmp_table)
      tmp_table_name
    end

    def transform_row(table_schemas_lookup, row_transformers, row)
      row_transformers.each do |t|
        row = t.transform(row)
      end

      return row if row.is_a? SkipRow

      is_named_rows = false
      raise "Row is not a Hash type, #{row.inspect}" unless row.is_a? Hash
      rows = if row.key?(table_schemas_lookup.keys[0])
               row
             else
               { table_schemas_lookup.keys[0] => row }
             end

      values_by_table = {}
      rows.each do |key, split_row|
        table_schema = table_schemas_lookup[key]

        split_rows = []
        split_rows = if split_row.is_a? Array
                       split_row
                     else
                       [split_row]
                     end

        split_rows.each do |r|
          values_arr = []
          table_schema.columns.keys.each do |c|
            values_arr << (r[c.to_sym] if r.key?(c.to_sym)) if @row_columns_symbolized
            values_arr << (r[c] if r.key?(c)) unless @row_columns_symbolized
          end
          if !values_by_table.key?(key)
            values_by_table[key] = [values_arr]
          else
            values_by_table[key] << values_arr
          end
        end
      end

      values_by_table
    end
  end

  class AddNewData
    def initialize(add_data_type)
      @add_data_type = add_data_type
    end

    def build_sql(tmp_table, destination_table_name, opts)
      sql = ""
      if @add_data_type == "append"
          sql = <<SQL
begin transaction;
  insert into #{destination_table_name} select * from #{tmp_table};
end transaction;
SQL
      elsif @add_data_type == "upsert"
          where_id_join = opts.fetch(:where_id_join)
          # Using recommended method to do upsert
          # http://docs.aws.amazon.com/redshift/latest/dg/merge-replacing-existing-rows.html
          sql = <<SQL
begin transaction;
  delete from #{destination_table_name} using #{tmp_table} #{where_id_join};
  insert into #{destination_table_name} select * from #{tmp_table};
end transaction;
SQL
      else
        raise "Unknown add data type #{@add_data_type}"
      end
      sql
    end
  end

  # class used as sentinel to skip a row.
  class SkipRow
  end
end
