require 'logger'
require_relative "./columnize.rb"

class ColumnLogger
  def initialize path, columns=[], width=nil, show_columns=true, colorize=true
    @logger = Logger.new path
    @logger.formatter = proc { |_,_,_,msg| msg + "\n" }
    @logger.info "Started"
    @columns = columns
    @width = width
    @show_columns = show_columns
    @last_obj = {}
    @colorize = colorize
  end

  def log obj
    if obj.respond_to? :values_at
      pairs = obj.values_at(*@columns).zip(@columns).map(&:reverse)
      changed_keys = if @last_obj && @colorize then obj.select { |k,v| v != @last_obj[k] }.keys else [] end
      @logger.info Hash[pairs].columnize(@width, @show_columns, changed_keys)
      @last_obj = obj
    else
      @logger.info "---------- #{obj}"
    end
  end

  def br
    @logger.info "-"*10
  end
end
