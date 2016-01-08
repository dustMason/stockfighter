require 'rubygems'
require 'bundler/setup'
require 'json'
require 'httparty'

class GMClient
  include HTTParty
  base_uri "https://www.stockfighter.io/gm"

  def initialize key
    @options = { headers: { "Cookie" => "api_key=#{key}" } }
  end

  def levels
    request(:get, "/levels")
  end

  def start_level level_name
    @current_level = level_name
    level_data = request(:post, "/levels/#{level_name}")
    @instanceId = level_data['instanceId']
    level_data
  end

  def stop_level instance_id
    request(:post, "/instances/#{instance_id}/stop")
  end

  def reset
    # convenience method for performing a full reset of current level
    if @instanceId and @current_level
      stop_level @instanceId
      start_level @current_level
    end
  end

  private

  def request method, path, options={}
    opts = @options.merge(options)
    begin
      JSON.load(self.class.send(method, path, opts).body)
    rescue JSON::ParserError => e
      puts "-> #{method} #{path} : #{e.message.strip}"
      {}
    end
  end
end
