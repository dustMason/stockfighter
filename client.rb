require 'rubygems'
require 'bundler/setup'

require 'json'
require 'httparty'

class Client
  include HTTParty
  base_uri "https://api.stockfighter.io/ob/api"

  def initialize key
    @options = { headers: { "X-Starfighter-Authorization" => key } }
  end

  def quote venue, stock
    get "/venues/#{venue}/stocks/#{stock}/quote"
  end

  def order_book venue, stock
    get "/venues/#{venue}/stocks/#{stock}"
  end

  def order venue, stock, order_data
    post "/venues/#{venue}/stocks/#{stock}/orders", order_data
  end

  def stock_order venue, stock, order_id
    get "/venues/#{venue}/stocks/#{stock}/orders/#{order_id}"
  end

  def stock_orders venue, account, stock
    get "/venues/#{venue}/accounts/#{account}/stocks/#{stock}/orders"
  end

  def cancel_order venue, stock, order_id
    delete "/venues/#{venue}/stocks/#{stock}/orders/#{order_id}"
  end

  private

  def get path
    request :get, path
  end

  def post path, body
    request :post, path, body: JSON.dump(body)
  end

  def delete path
    request :delete, path
  end

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

