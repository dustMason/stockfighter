require 'pp'
require_relative 'lib/lib.rb'

apikey = File.open("apikey").read
gm_client = GMClient.new apikey

level_data = gm_client.start_level "sell_side"
# to do a full reset:
level_data = gm_client.reset
venue = level_data["venues"].first
stock = level_data["tickers"].first
account = level_data["account"]

class Trader
  def initialize key, account, venue, stock
    @client = Client.new key
    @account = account
    @venue = venue
    @stock = stock

    @cash = 0
    @shares_held = 0 # shares
    @nav = 0 # net asset value

    @open_orders = []
    @target_price = 0

    @price_interval = 33 # cents
    @trade_amount = 200 # shares
    @price_ticks = 2 # how many orders to make in each set, above AND below @target_price
  end

  def trade
    cancel_outstanding_orders
    inspect_order_book
    get_target_price
    create_order_set if @target_price > 0
  end

  private

  def cancel_outstanding_orders
    @open_orders.each do |order|
      fresh_order_data = @client.cancel_order @venue, @stock, order["id"]
      update_position_with fresh_order_data
    end
    @open_orders = []
    puts "===> position is $#{@cash/100.0} cash, #{@shares_held} shares held, $#{@nav/100.0} NAV"
  end

  def inspect_order_book
    book = @client.order_book @venue, @stock
    bids = (book["bids"] || []).map { |b| b["price"].to_i }
    asks = (book["asks"] || []).map { |a| a["price"].to_i }
    @target_bid = bids.median
    @target_ask = asks.median
    puts ""
    puts "="*50
    pp book["bids"]
    puts "_"*50
    pp book["asks"]
    puts "="*50
    puts "bid: #{@target_bid}, ask: #{@target_ask}"
    puts ""
  end

  def get_target_price
    quote = @client.quote(@venue, @stock)
    ask, bid = quote["ask"].to_i, quote["bid"].to_i
    @target_price = (ask + bid) / 2
    puts "=> set target price at #{@target_price}"
  end

  def create_order_set
    padding = @shares_held / 2
    (1..@price_ticks).to_a.map do |n|
      order(@target_bid - (n*@price_interval), "buy", @trade_amount - padding + 1) if @target_bid && @shares_held < 1000
      order(@target_ask + (n*@price_interval), "sell", @trade_amount + padding + 1) if @target_ask
    end
    puts ""
  end

  def order price, direction, qty
    if qty.abs > 0
      print "."
      data = {
        "account" => @account,
        "venue" => @venue,
        "symbol" => @stock,
        "price" => price,
        "qty" => qty.abs,
        "direction" => direction,
        "orderType" => "limit"
      }
      order = @client.order(@venue, @stock, data)
      @open_orders << order if order["id"]
      if !order["id"]
        pp order
      end
    end
  end

  def update_position_with order
    if order['totalFilled'] > 0
      subtotal = (order["price"].to_i * order["totalFilled"].to_i)
      qty = order["totalFilled"].to_i
      if order["direction"] == "buy"
        @cash -= subtotal
        @shares_held += qty
      else
        @cash += subtotal
        @shares_held -= qty
      end
      @nav = @cash + (@shares_held * @target_price)
    end
  end

  def order_status order
    "#{order['direction']} #{order['totalFilled']} of #{order['originalQty']} shares at #{order['price']}"
  end
end

trader = Trader.new apikey, account, venue, stock

loop do
  trader.trade
  sleep 6
end
