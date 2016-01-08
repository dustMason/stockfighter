require 'eventmachine'
require 'faye/websocket'
require_relative './client.rb'
require_relative './gm_client.rb'
require_relative './array_median.rb'
require_relative './money.rb'
require_relative './column_logger.rb'
require_relative './stats.rb'

apikey = File.open("apikey").read

gm_client = GMClient.new apikey
level_data = gm_client.start_level "sell_side"

# to do a full reset:
# level_data = gm_client.reset

venue = level_data["venues"].first
stock = level_data["tickers"].first
account = level_data["account"]

puts "=> Started game #{level_data['instanceId']}. account #{account}. venue #{venue}. stock #{stock}"

quotes_uri = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{venue}/tickertape/stocks/#{stock}"
fills_uri  = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{venue}/executions/stocks/#{stock}"

class Trader
  attr_reader :shares_held

  def initialize key, account, venue, stock
    @logger = ColumnLogger.new("dueling_bulldozers.log", %i(id action originalQty qty price), 80, false, false)
    @stats = Stats.new

    @client = Client.new key
    @account = account
    @venue = venue
    @stock = stock

    @cash = 0
    @shares_held = 0 # shares
    @nav = 0 # net asset value
    @last = 0
    @bid = nil
    @ask = nil
    @last_bid = 0
    @last_ask = 0

    @chilling_out = false

    @avg_cost_basis = 0

    @orders = {} # order_id => order_data hash

    @price_interval = 1 # cents
    @trade_amount = 100 # shares
    @price_ticks = 3 # how many orders to make in each set, above AND below @target_price
    @order_delay = 5 # seconds to wait before sending an order after a quote
  end

  def trade
    status
    @logger.br
    cancel_orders @orders
    create_orders
    place_orders
    start_trade_timer # unless @last_ask == @ask || @last_bid == @bid
  end

  def tricky
    @logger.log "tricky"
    @orders_to_place = []
    # bait the bots by causing a string of small orders, pushing the bid down
    (1..@price_ticks).to_a.each do |n|
      price = @ask + (n*10)
      @orders_to_place << sell(price)
      @orders_to_place << buy(price)
    end
    place_orders
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
      interval: @price_interval
    }
    print contents.columnize + "\r"
  end

  def update_order_book quote
    @ask ||= quote["ask"] if quote["ask"]
    @bid ||= quote["bid"] if quote["bid"]
    @last_ask = quote["ask"] if quote["ask"]
    @last_bid = quote["bid"] if quote["bid"]
    @last = quote["last"] if quote["last"]
    @nav = @cash + (@shares_held * @last) if @last
    examine_quote quote
    trade unless @chilling_out
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
      @logger.log({id: order["id"], action: "bought", price: fill['price'].money, qty: filled})
      calculate_cost_basis
    elsif order["direction"] == "sell"
      @cash += subtotal
      @shares_held -= filled
      @stats.g "sold", fill["price"]/100.0
      @logger.log({id: order["id"], action: "sold", price: fill['price'].money, qty: filled})
    end
    @stats.g "shares", @shares_held
    status
  end

  private

  def send_quote_stats
    @stats.batch(
      bid: @last_bid/100.0,
      ask: @last_ask/100.0,
      nav: @nav/100.0,
      last: @last/100.0
    )
  end

  def start_trade_timer
    @timer.cancel if @timer
    @chilling_out = true
    @timer = EventMachine::Timer.new @order_delay, proc { @chilling_out = false }
  end

  def examine_quote quote
    @bid_stack ||= []
    @ask_stack ||= []

    @price_interval = (@last * 0.005).to_i

    # @bid = ((@last_ask + @last_bid) / 2) - 1
    # @ask = ((@last_ask + @last_bid) / 2)

    @bid = @last_bid + 1
    @ask = @last_ask - 1

    # if @last_quote && @last_quote["bid"] != quote["bid"] && quote["bid"]
    #   @bid_stack << quote["bid"]
    # else
    #   if @bid_stack.size > 1
    #     intervals = @bid_stack.each_cons(2).map { |p| (p[1] - p[0]).abs if p[1] and p[0] }.compact
    #     if intervals.size > 1
    #       @bid = @bid_stack.max
    #     end
    #     @bid_stack = []
    #   end
    # end
    #
    # if @last_quote && @last_quote["ask"] != quote["ask"] && quote["ask"]
    #   @ask_stack << quote["ask"]
    # else
    #   if @ask_stack.size > 1
    #     intervals = @ask_stack.each_cons(2).map { |p| (p[1] - p[0]).abs if p[1] and p[0] }.compact
    #     if intervals.size > 1
    #       @ask = @ask_stack.min
    #     end
    #     @ask_stack = []
    #   end
    # end

    @last_quote = quote
  end

  def calculate_cost_basis
    if @orders.keys.size > 0
      orders = @orders.select { |_,v| v["totalFilled"] > 0 && v["direction"] == "buy" }.values
      if orders.size > 0
        @avg_cost_basis = (orders.reduce(0) { |sum, o| sum + o["price"] }) / orders.size
        # the above is supposed to be more like this:
        # sum + ((o["fills"].reduce(0) { |fsum, f| fsum + f["price"] }) / o["fills"].size)
      end
    end
  end

  def cancel_orders orders
    threads = []
    orders.each_pair do |order_id, order|
      threads << Thread.new do
        cancel = @client.cancel_order @venue, @stock, order_id
        @orders.delete order_id
        @logger.log({id: order_id, action: "cancel", originalQty: cancel["originalQty"], filled: cancel["totalFilled"]})
      end
    end
    threads.map(&:join)
  end

  def create_orders
    @orders_to_place = []
    if safe?
      (1..@price_ticks).to_a.reverse.each do |n|
        @orders_to_place << buy(target_bid - (n*@price_interval) - rand(2)) if !too_long? && safe_to_buy?
        @orders_to_place << sell(target_ask + (n*@price_interval) + rand(2)) if !too_short? && safe_to_sell?
      end
    end
  end

  def target_bid
    @bid if @bid
  end

  def target_ask
    @ask if @ask
  end

  def buy target_price, amount=nil
    create_order(target_price.to_i, "buy", (amount || @trade_amount))
  end

  def sell target_price, amount=nil
    create_order(target_price.to_i, "sell", (amount || @trade_amount))
  end

  def too_short?
    @shares_held - @trade_amount < -699 + (@price_ticks * @trade_amount)
  end

  def too_long?
    @shares_held + @trade_amount > 699 - (@price_ticks * @trade_amount)
  end

  def safe?
    target_bid && target_bid > 5 &&
    target_ask && target_ask > 5 &&
    target_bid < target_ask
  end

  def safe_to_buy?
    true
    # @avg_cost_basis == 0 || (target_bid + (@price_interval * @price_ticks)) < @avg_cost_basis + 350
  end

  def safe_to_sell?
    true
    # @avg_cost_basis == 0 || (target_ask - (@price_interval * @price_ticks)) > @avg_cost_basis - 350
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

  def place_orders
    threads = []
    @orders_to_place.each do |o|
      threads << Thread.new do
        place_order(o)
      end
    end
    @stats.batch_a threads.map(&:value)
  end

  def place_order data
    order = @client.order(@venue, @stock, data)
    @logger.log({id: order["id"], action: data["direction"], price: data["price"].money, qty: data["qty"]})
    # @stats.g data["direction"], data["price"]/100.0
    @orders[order["id"]] = order if order["id"]
    { series: data["direction"], values: { value: data["price"]/100.0 } }
  end
end

EM.run do
  fills = Faye::WebSocket::Client.new(fills_uri)
  quotes = Faye::WebSocket::Client.new(quotes_uri)
  trader = Trader.new apikey, account, venue, stock
  log_cols = %w{bid ask bidSize askSize bidDepth askDepth last lastSize}
  quote_logger = ColumnLogger.new("dueling_bulldozers_quotes.log", log_cols, 140)

  # EM.add_periodic_timer(10) do
  #   trader.tricky
  # end

  fills.on :message do |event|
    data = JSON.load(event.data)
    trader.update_position_with data
  end

  quotes.on :message do |event|
    begin
      data = JSON.load(event.data)
      quote_logger.log(data["quote"].select { |k,_| log_cols.include? k })
      trader.update_order_book(data["quote"]) if data["quote"]
    rescue JSON::ParserError => e
      # puts "-> Error : #{e.message}"
    end
  end

  Signal.trap("INT")  { EventMachine.stop }
  Signal.trap("TERM") { EventMachine.stop }
end
