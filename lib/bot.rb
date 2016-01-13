require_relative './array_median.rb'
require_relative './client.rb'
require_relative './columnize.rb'
require_relative './money.rb'
require_relative './stats.rb'

class Bot
  attr_reader :client, :stats, :nav, :cash, :shares_held
  attr_accessor :silent, :last

  def initialize key, account, venue, stock
    @stats = Stats.new
    @client = Client.new key
    @account = account
    @venue = venue
    @stock = stock
    @silent = false
    @cash = 0
    @shares_held = 0 # shares
    @nav = 0 # net asset value
    @last = 0
    @last_bid = 0
    @last_ask = 0
    @orders = {} # order_id => order_data hash
    @trade_amount = 500 # shares
  end

  def status
    contents = {
      cash: @cash.money,
      shares: @shares_held,
      nav: @nav.money,
      last_bid: (@last_bid || 0).money,
      last_ask: (@last_ask || 0).money,
      last: (@last || 0).money
    }
    print contents.columnize + "\r" unless @silent
  end

  def update_order_book quote
    @last_ask = quote["ask"] if quote["ask"]
    @last_bid = quote["bid"] if quote["bid"]
    @last = quote["last"] if quote["last"]
    @nav = @cash + (@shares_held * @last) if @last
    post_order_book_update_hook quote
    status
    send_quote_stats unless @silent
  end

  def update_position_with fill
    filled = fill["filled"]
    subtotal = (fill["price"] * filled)
    order = fill["order"]
    if @orders[order["id"]] then @orders[order["id"]] = order end
    if order["direction"] == "buy"
      @cash -= subtotal
      @shares_held += filled
      @stats.g "bought", fill["price"]/100.0 unless @silent
    elsif order["direction"] == "sell"
      @cash += subtotal
      @shares_held -= filled
      @stats.g "sold", fill["price"]/100.0 unless @silent
    end
    @stats.g "shares", @shares_held unless @silent
    post_position_update_hook
    status
  end

  # override me:
  def post_position_update_hook; end
  def post_order_book_update_hook quote; end

  private

  def send_quote_stats
    @stats.batch(
      bid: @last_bid/100.0,
      ask: @last_ask/100.0,
      nav: @nav/100.0,
      last: @last/100.0,
      cash: @cash/100.0
    ) unless @silent
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

  def buy target_price, amount=nil
    create_order(target_price.to_i, "buy", (amount || @trade_amount))
  end

  def sell target_price, amount=nil
    create_order(target_price.to_i, "sell", (amount || @trade_amount))
  end

  def too_short?
    @shares_held - @trade_amount < -1000
  end

  def too_long?
    @shares_held + @trade_amount > 1000
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

  def place_orders orders=[]
    threads = []
    orders.each do |o|
      threads << Thread.new { place_order(o) }
    end
    @stats.batch_a threads.map(&:value)
  end

  def place_order data
    order = @client.order(@venue, @stock, data)
    @orders[order["id"]] = order if order["id"]
    { series: data["direction"], values: { value: data["price"]/100.0 } }
  end
end
