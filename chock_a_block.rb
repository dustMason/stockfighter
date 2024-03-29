require_relative 'lib/lib.rb'

apikey = File.open("apikey").read
gm_client = GMClient.new apikey

level_data = gm_client.start_level "chock_a_block"
# to do a full reset:
# level_data = gm_client.reset
venue = level_data["venues"].first
stock = level_data["tickers"].first
account = level_data["account"]

class Trader
  def initialize key, account, venue, stock
    @client = Client.new key
    @account = account
    @venue = venue
    @stock = stock
    fetch_orders
  end

  def buy total_shares, increment, target_price
    fetch_orders
    if shares_held + outstanding_bids < total_shares && outstanding_bids < (increment * 3)
      print "-"
      price = best_bid_for(target_price)
      if price
        puts "=> buying at #{price}"
        order = {
          "account" => @account,
          "venue" => @venue,
          "symbol" => @stock,
          "price" => price,
          "qty" => increment,
          "direction" => "buy",
          "orderType" => "limit"
        }
        @client.order @venue, @stock, order
      end
    else
      print "."
    end
  end

  def shares_held
    @orders.reduce(0) { |sum, order| sum + (order["totalFilled"] || 0) }
  end

  private

  def best_bid_for target_price
    ask = @client.quote(@venue, @stock)["ask"].to_i
    return ask if ask <= target_price
  end

  def fetch_orders
    @orders = @client.stock_orders(@venue, @account, @stock)["orders"]
  end

  def outstanding_bids
    @orders.reduce(0) { |sum, order| sum + (order["qty"] || 0) }
  end
end

trader = Trader.new apikey, account, venue, stock

until trader.shares_held >= 100_000

  trader.buy 100_000, 1000, 6645
  sleep 2

end
