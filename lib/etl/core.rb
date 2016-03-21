libdir = File.expand_path("..", __FILE__)
$LOAD_PATH.unshift(libdir)

# Pre-define the module so we can use simpler syntax
module ETL
end

require 'sequel'

# Core classes
require 'etl/exception.rb'

# Utilities
require 'etl/util/logger.rb'
require 'etl/util/hash_util.rb'
require 'etl/util/string_util.rb'
require 'etl/batch.rb'

# Models
# Set up the database connection that's needed for Sequel models
# Also we can use the DB constant in the rest of the code
DB = Sequel::Model.db = Sequel.connect(ETL.config.core[:database])
Sequel::Model.plugin :timestamps
require 'etl/models/job_run.rb'

# Schema management
require 'etl/schema/table.rb'
require 'etl/schema/column.rb'

base_file = 'base.rb'
%w( job input output transform queue batch_factory schedule ).each do |d|
  dir = "#{libdir}/#{d}"
  require "#{dir}/#{base_file}"
  Dir.new(dir).each do |file|
    next unless file =~ /\.rb$/
    next if file == base_file
    require "#{dir}/#{file}"
  end
end

module ETL
  
  # Generic App-wide logger
  def ETL.logger
    @@logger ||= ETL.create_logger
  end
  
  # Sets generic App-wide logger
  def ETL.logger=(v)
    @@logger = v
  end
  
  # Creates a new logger instance that we can use for different contexts 
  # based on 
  def ETL.create_logger(context = {})
    log = ETL.create_class(:log)
    log.context = context.dup
    log
  end
  
  def ETL.queue
    @@queue ||= ETL.create_queue
  end
  
  def ETL.queue=(v)
    @@queue = v
  end
  
  def ETL.create_queue
    ETL.create_class(:queue)
  end  
  
  # Helper function to create a class given a class name stored in the config
  # under "sym"
  def ETL.create_class(sym)
    cfg = ETL.config.core[sym]
    Object::const_get(cfg[:class]).new(cfg)
  end
end  
