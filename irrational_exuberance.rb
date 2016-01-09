require 'eventmachine'
require 'faye/websocket'

require_relative './gm_client.rb'
require_relative './bot.rb'

apikey = File.open("apikey").read

gm_client = GMClient.new apikey
level_data = gm_client.start_level "irrational_exuberance"

# to do a full reset:
level_data = gm_client.reset

venue = level_data["venues"].first
stock = level_data["tickers"].first
account = level_data["account"]

puts "=> Started game #{level_data['instanceId']}. account #{account}. venue #{venue}. stock #{stock}"

quotes_uri = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{venue}/tickertape/stocks/#{stock}"
fills_uri  = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{venue}/executions/stocks/#{stock}"

class Trader < Bot
  def pump_dump
    # think like momo:
    # "oh look, the stock is rising i must buy"
  end
end

EM.run do
  fills = Faye::WebSocket::Client.new(fills_uri)
  quotes = Faye::WebSocket::Client.new(quotes_uri)
  trader = Trader.new apikey, account, venue, stock

  EM.add_periodic_timer(4) do
    trader.pump_dump
  end

  fills.on :message do |event|
    data = JSON.load(event.data)
    trader.update_position_with data
  end

  quotes.on :message do |event|
    begin
      data = JSON.load(event.data)
      trader.update_order_book(data["quote"]) if data["quote"]
    rescue JSON::ParserError => e
      # puts "-> Error : #{e.message}"
    end
  end

  Signal.trap("INT")  { EventMachine.stop }
  Signal.trap("TERM") { EventMachine.stop }
end
