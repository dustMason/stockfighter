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

    @peak_price ||= 0
    @peak_price = @last if @last > @peak_price

    @recent_quotes ||= []
    @recent_quotes.unshift @last
    @recent_quotes.slice!(0,100) if @recent_quotes.size > 100
    @avg_quote = @recent_quotes.median

    if @last > 10
      @starting_price ||= @last
    end
    if @starting_price
      cancel_orders @orders
      orders = []
      if !@party_time
        # start off by getting a large holding while its cheap
        # and make money money money
        orders << buy((@last * 1.03).to_i, 350)
        orders << sell((@last * 1.05).to_i, 20)
      end
      if @last > @starting_price * 2.0
        # i'm rich, flip the switch
        @party_time = true
      end
      if @shares_held > 200 && @party_time
        # join the party, keep selling into the rising stock until my holding is small
        orders << sell(@last+5, rand(200)+100)
      elsif @party_time && @last > (@starting_price + 500)
        # once i'm sold down, try to tank the market
        target = [@avg_quote, @last].min
        orders << buy((@last * 0.995).to_i, rand(5)+50)
        (1..6).to_a.each do |n|
          orders << sell((target - (n*0.004)).to_i, (rand(5)+1)*2)
        end
        orders << sell((target / 1.1).to_i, (rand(5)+1)*10)
        orders << sell((target / 1.25).to_i, (rand(5)+1)*10)
        orders << sell((target / 1.5).to_i, (rand(5)+1)*10)
        orders << sell((target / 2).to_i, (rand(5)+1)*10)
      elsif @party_time && @last <= (@starting_price * 1.2) && @shares_held < 0
        orders << buy(target, @shares_held * -1)
      end
      place_orders(orders)
    end
  end
end

EM.run do
  fills = Faye::WebSocket::Client.new(fills_uri)
  quotes = Faye::WebSocket::Client.new(quotes_uri)
  trader = Trader.new apikey, account, venue, stock

  EM.add_periodic_timer(5) do
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
