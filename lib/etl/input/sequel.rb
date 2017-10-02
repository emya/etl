require 'sequel'

module ETL::Input

  # Input class that uses Sequel connection for accessing data. Currently it
  # just supports raw SQL with query param replacement.
  # https://github.com/jeremyevans/sequel
  class Sequel < Base
    attr_accessor :params, :sql, :sql_params, :test_connection, :disconnect_required

    # Construct reader based on Sequel connection params and SQL query
    def initialize(params, sql = nil, sql_params = nil)
      super()
      @params = params
      @sql = sql
      @sql_params = sql_params
      @conn = nil
      @test_connection = false
    end

    def conn
      @conn ||= ::Sequel.connect(@params)
      @conn.test_connection if @test_connection
      @conn
    end

    # Display connection string for this input
    # TODO: Add table name to this - easier if we're given a Sequel dataset
    def name
      "Sequel #{@params[:adapter]}:#{@params[:user]}@#{@params[:host]}/#{@params[:database]}"
    end

    def query_debug_str
      str = "Executing Sequel query #{@sql}"
      unless @sql_params.nil? || @sql_params.empty?
        if @sql_params.respond_to?(:join)
          param_str = @sql_params.join(", ")
        elsif
          param_str = @sql_params.to_s
        end
        str += " with params #{param_str}"
      else
        str += " with no params"
      end
      str
    end

    # Reads each row from the query and passes it to the specified block.
    def each_row(batch = ETL::Batch.new)
      log.debug(query_debug_str)

      # block used to process each row
      row_proc = Proc.new do |row_in|
        row = {}

        # Sequel returns columns as symbols so we need to translate to strings
        row_in.each do |k, v|
          row[k.to_s] = v
        end

        transform_row!(row)
        yield row
        @rows_processed += 1
      end

      @rows_processed = 0
      # need to splat differently depending on params type
      if @sql_params.is_a?(Hash)
        conn.fetch(sql, **@sql_params, &row_proc)
      else
        conn.fetch(sql, *@sql_params, &row_proc)
      end
      conn.disconnect if @disconnect_required
    end
  end
end
