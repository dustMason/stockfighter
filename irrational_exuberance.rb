require 'eventmachine'
require 'faye/websocket'
require_relative 'lib/lib.rb'

apikey = File.open("apikey").read
gm_client = GMClient.new apikey
level_data = gm_client.start_level "irrational_exuberance"
# to do a full reset:
# level_data = gm_client.reset
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
    if @starting_price
      cancel_orders @orders
      orders = []
      if !@party_time
        # start off by getting a large holding while its cheap
        # and make money money money
        orders << buy((@last * 1.03).to_i, 350)
        orders << sell((@last * 1.05).to_i, 20)
      end

      if @time_to_get_out
        orders << buy(@last, @shares_held * -1)
      elsif @party_time
        if @shares_held > 450
          # join the party, keep selling into the rising stock until my holding is small
          orders << sell(@last, rand(200)+100)
        elsif @last > @crash_target
          # once i'm sold down, try to tank the market
          target = [@avg_quote, @last].min
          orders << buy((@last * 0.995).to_i, rand(5)+50)
          (3..10).to_a.each do |n|
            orders << sell((target - (n*0.004)).to_i, (rand(5)+1)*100)
            orders << sell((target / n).to_i, (rand(5)+1)*100)
            orders << buy((target - (n*0.004)).to_i + 3, (rand(5)+1)*100)
            orders << buy((target / n).to_i + 3, (rand(5)+1)*100)
            orders << buy((target / n).to_i - 10, (rand(5)+1)*100)
          end
        end
      end
      place_orders(orders)
    end
  end

  def post_order_book_update_hook
    @ticks_below_target ||= 0
    if @last > 10
      @starting_price ||= @last
    end
    if @starting_price && @last > @starting_price * 8
      @party_time = true # i'm rich, flip the switch
    end
    @peak_price ||= 0
    if @last > @peak_price
      @peak_price = @last
      @crash_target = @peak_price - (@peak_price * 0.82).to_i
    end
    @recent_quotes ||= []
    @recent_quotes.unshift @last
    @recent_quotes.slice!(0,50) if @recent_quotes.size > 50
    @avg_quote = @recent_quotes.median
    if @crash_target && @avg_quote <= @crash_target && @party_time
      @ticks_below_target += 1
    end
    if @ticks_below_target > 5
      @time_to_get_out = true
    end
  end

  def status
    contents = {
      cash: @cash.money,
      shares: @shares_held,
      nav: @nav.money,
      last: (@last || 0).money,
      crash_target: (@crash_target || 0).money,
      avg_quote: (@avg_quote || 0).money,
      out: @time_to_get_out,
      party: @party_time,
      ticks: @ticks_below_target
    }
    print contents.columnize + "\r"
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
