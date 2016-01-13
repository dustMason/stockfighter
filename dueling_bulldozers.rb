require 'eventmachine'
require 'faye/websocket'
require_relative 'lib/lib.rb'

apikey = File.open("apikey").read

gm_client = GMClient.new apikey
level_data = gm_client.start_level "dueling_bulldozers"

# to do a full reset:
level_data = gm_client.reset

venue = level_data["venues"].first
stock = level_data["tickers"].first
account = level_data["account"]

puts "=> Started game #{level_data['instanceId']}. account #{account}. venue #{venue}. stock #{stock}"

quotes_uri = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{venue}/tickertape/stocks/#{stock}"
fills_uri  = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{venue}/executions/stocks/#{stock}"

class Trader
  attr_reader :shares_held

  def initialize key, account, venue, stock
    @stats = Stats.new
    @client = Client.new key
    @account = account
    @venue = venue
    @stock = stock

    @cash = 0
    @shares_held = 0 # shares
    @nav = 0 # net asset value
    @last = 0
    @last_bid = 0
    @last_ask = 0

    @recent_bids = []
    @avg_bid = 0
    @recent_asks = []
    @avg_ask = 0

    @chilling_out = false

    @avg_cost_basis = 0

    @orders = {} # order_id => order_data hash

    @price_interval = 1 # cents
    @trade_amount = 99 # shares
    @price_ticks = 4 # how many orders to make in each set, above AND below @target_price
    @order_delay = 5
  end

  def status
    contents = {
      cash: @cash.money,
      shares: @shares_held,
      nav: @nav.money,
      my_bid: (target_bid || 0).money,
      last_bid: (@last_bid || 0).money,
      my_ask: (target_ask || 0).money,
      last_ask: (@last_ask || 0).money,
      last: (@last || 0).money,
      cost_basis: @avg_cost_basis.money,
      interval: @price_interval,
      avg_ask: @avg_ask,
      avg_bid: @avg_bid
    }
    print contents.columnize + "\r"
  end

  def update_order_book quote
    @last_ask = quote["ask"] if quote["ask"]
    @last_bid = quote["bid"] if quote["bid"]
    @last = quote["last"] if quote["last"]
    @nav = @cash + (@shares_held * @last) if @last
    @price_interval = (@last * 0.000534).to_i
    calculate_average_bid
    calculate_average_ask
    status
    send_quote_stats
  end

  def update_position_with fill
    filled = fill["filled"]
    subtotal = (fill["price"] * filled)
    order = fill["order"]

    if @orders[order["id"]] then @orders[order["id"]] = order end

    if order["direction"] == "buy"
      @cash -= subtotal
      @shares_held += filled
      @stats.g "bought", fill["price"]/100.0
      calculate_cost_basis
    elsif order["direction"] == "sell"
      @cash += subtotal
      @shares_held -= filled
      @stats.g "sold", fill["price"]/100.0
    end
    @stats.g "shares", @shares_held
    status
  end

  # strategies
  # ###

  # just do a standard numberline style set of orders based on target_ask and target_bid
  def boring
    create_orders
    place_orders
    EventMachine::Timer.new 4, proc { cancel_orders(@orders.select { |_,o| o["long_term"].nil? }) }
  end

  # always be trawlin' with some low hanging orders on the books
  def trawlin
    @trawls = []
    @trawls << buy((target_bid * 0.65).to_i, 400)
    @trawls << sell((target_ask * 1.3).to_i, 400)
    place_orders @trawls
    EventMachine::Timer.new 29, proc { cancel_orders(@orders.select { |_,o| o["long_term"] == true }) }
  end

  private

  def calculate_average_bid
    @recent_bids.unshift @last_bid
    if @recent_bids.size > 200
      @recent_bids.slice!(0,200)
    end
    @avg_bid = @recent_bids.median
  end

  def calculate_average_ask
    @recent_asks.unshift @last_ask
    if @recent_asks.size > 200
      @recent_asks.slice!(0,200)
    end
    @avg_ask = @recent_asks.median
  end

  def send_quote_stats
    @stats.batch(
      bid: @last_bid/100.0,
      ask: @last_ask/100.0,
      nav: @nav/100.0,
      last: @last/100.0,
      avg_bid: @avg_bid/100.0,
      avg_ask: @avg_ask/100.0,
      cash: @cash/100.0
    )
  end

  def start_trade_timer
    @timer.cancel if @timer
    @chilling_out = true
    @timer = EventMachine::Timer.new @order_delay, proc { @chilling_out = false }
  end

  def calculate_cost_basis
    if @orders.keys.size > 0
      orders = @orders.select { |_,v| v["totalFilled"] > 0 && v["direction"] == "buy" }.values.uniq { |o| o["id"] }
      if orders.size > 0
        # @avg_cost_basis = (orders.reduce(0) { |sum, o| sum + o["price"] }) / orders.size
        @avg_cost_basis = orders.reduce(0) { |sum, o|
          fills = o["fills"].uniq { |f| f["qty"] }.map { |f| f["price"] }
          sum + fills.median
        } / orders.size
      end
    end
  end

  def cancel_orders orders
    threads = []
    orders.each_pair do |order_id, order|
      threads << Thread.new do
        cancel = @client.cancel_order @venue, @stock, order_id
        @orders.delete order_id
      end
    end
    threads.map(&:join)
  end

  def create_orders
    @orders_to_place = []
    if sane?
      (1..@price_ticks).to_a.reverse.each do |n|
        @orders_to_place << buy(target_bid - (n*@price_interval)) if !too_long? && safe_to_buy?
        @orders_to_place << sell(target_ask + (n*@price_interval)) if !too_short? && safe_to_sell?
      end
    end
  end

  def target_bid
    @avg_bid
  end

  def target_ask
    @avg_ask
  end

  def buy target_price, amount=nil
    create_order(target_price.to_i, "buy", (amount || @trade_amount))
  end

  def sell target_price, amount=nil
    create_order(target_price.to_i, "sell", (amount || @trade_amount))
  end

  def too_short?
    @shares_held - @trade_amount < -600 + (@price_ticks * @trade_amount)
  end

  def too_long?
    @shares_held + @trade_amount > 600 - (@price_ticks * @trade_amount)
  end

  def sane?
    target_bid && target_bid > 5 &&
    target_ask && target_ask > 5 &&
    target_bid < target_ask
  end

  def safe_to_buy?
    true
    # @avg_cost_basis == 0 || (target_bid + (@price_interval * @price_ticks)) < @avg_cost_basis + 350
  end

  def safe_to_sell?
    @avg_cost_basis == 0 || (target_ask - (@price_interval * @price_ticks)) > @avg_cost_basis - 350
  end

  def create_order price, direction, qty
    qty = qty.abs
    if qty > 0
      data = {
        "account" => @account,
        "venue" => @venue,
        "symbol" => @stock,
        "price" => price,
        "qty" => qty,
        "direction" => direction,
        "orderType" => "limit"
      }
    end
  end

  def place_orders orders=nil
    threads = []
    (orders || @orders_to_place).each do |o|
      threads << Thread.new { place_order(o, !orders.nil?) }
    end
    @stats.batch_a threads.map(&:value)
  end

  def place_order data, long_term=false
    order = @client.order(@venue, @stock, data)
    # @stats.g data["direction"], data["price"]/100.0
    order["long_term"] = true if long_term
    @orders[order["id"]] = order if order["id"]
    { series: data["direction"], values: { value: data["price"]/100.0 } }
  end
end

EM.run do
  fills = Faye::WebSocket::Client.new(fills_uri)
  quotes = Faye::WebSocket::Client.new(quotes_uri)
  trader = Trader.new apikey, account, venue, stock

  EM.add_periodic_timer(5) do
    trader.boring
  end
  EM.add_periodic_timer(30) do
    trader.trawlin
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
