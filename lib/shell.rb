require 'eventmachine'
require 'faye/websocket'
require 'pry'
require_relative './gm_client.rb'
require_relative './bot.rb'

APIKEY = File.open("apikey").read.strip

gm_client = GMClient.new APIKEY
level_data = gm_client.start_level "making_amends"

@venue = level_data["venues"].first
@stock = level_data["tickers"].first
@account = level_data["account"]

puts "=> Started game #{level_data['instanceId']}. account #{@account}. venue #{@venue}. stock #{@stock}"

quotes_uri = "wss://api.stockfighter.io/ob/api/ws/#{@account}/venues/#{@venue}/tickertape/stocks/#{@stock}"
fills_uri  = "wss://api.stockfighter.io/ob/api/ws/#{@account}/venues/#{@venue}/executions/stocks/#{@stock}"

class Trader < Bot
  attr_accessor :accounts

  def initialize *args
    @accounts = {}
    @last_order_id_checked = 0
    @spying = {} # hash of account num => { bot, socket }
    super *args
  end

  def status
  end

  def watch_account account
    uri  = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{@venue}/executions/stocks/#{@stock}"
    fills = Faye::WebSocket::Client.new(uri)
    dummy_bot = Bot.new APIKEY, account, @venue, @stock
    fills.on :message do |event|
      data = JSON.load(event.data)
      dummy_bot.update_position_with data
    end
    @spying[account] = { bot: dummy_bot, socket: fills }
  end

  def unwatch_account account
    @spying.delete account
  end

  def account_status account
    bot = @spying[account][:bot]
    data = {
      nav: bot.nav,
      shares: bot.shares_held,
      cash: bot.cash
    }
    data
  end

  def harvest_account_numbers count=20
    threads = []
    (1..count).to_a.each do |n|
      threads << Thread.new do
        cancel = @client.cancel_order @venue, @stock, n+@last_order_id_checked
        err = cancel["error"]
        account = err.split("account ").last.split(".").first
        if is_account_number?(account)
          print "."
          @accounts[account] ||= 1
          @accounts[account] += 1
        else
          print "x"
        end
      end
    end
    threads.map(&:join)
    @last_order_id_checked += count
  end


  private

  def is_account_number? string
    !string.start_with? "order"
  end

end

bot = Trader.new APIKEY, @account, @venue, @stock

binding.pry
