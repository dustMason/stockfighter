require 'rubygems'
require 'bundler/setup'
require 'colorize'

class Hash
  def columnize width=nil, show_columns=true, highlight_keys=[]
    width ||= `tput cols`.to_i
    width = width / self.keys.size
    self.map do |k,v|
      col = "%-#{width}s" % "#{k if show_columns} #{v}" 
      if highlight_keys.include? k
        col = col.colorize(:red)
      end
      col
    end.join()
  end
end
