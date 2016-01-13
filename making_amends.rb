require 'eventmachine'
require 'faye/websocket'
require 'awesome_print'
require 'pry'

require_relative 'lib/lib.rb'

APIKEY = File.open("apikey").read

gm_client = GMClient.new APIKEY
level_data = gm_client.start_level "making_amends"
venue = level_data["venues"].first
stock = level_data["tickers"].first
account = level_data["account"]

# to do a full reset:
# level_data = gm_client.reset


fills_uri  = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{venue}/executions/stocks/#{stock}"
class Trader < Bot
  attr_accessor :accounts, :spying

  def initialize *args
    @accounts = {}
    @last_order_id_checked = 0
    @spying = {} # hash of account num => { bot, socket }
    @standings = {} # hash of account num => bot.nav
    @wins = Hash.new(0) # hash of account num => win count (times change in nav and cash was positive)
    @losses = Hash.new(0) # hash of account num => loss count (times change in nav and cash was negative)
    super *args
  end

  def post_order_book_update_hook quote
    @spying.each do |account, hash|
      hash[:bot].update_order_book quote
    end
  end

  def status
  end

  def report
    puts "\n" + ("="*80)
    puts "=> #{@stock} price is #{@last.money}"
    @spying.each do |account, hash|
      ap account_status(account), multiline: false
    end
  end

  def winners_report
    @standings = Hash[@spying.map { |account, hash| [ account, { nav: hash[:bot].nav, cash: hash[:bot].cash } ] } ]
    if !@previous_standings.nil? && !@standings.empty?
      puts "\n" + ("="*80)
      puts "=> #{@stock} price is #{@last.money} (#{(@last - @previous_stock_price).money} change)"
      winners, losers = 0, 0
      movement = Hash[
        @standings.map do |account, hash|
          nav_change = hash[:nav] - @previous_standings[account][:nav]
          cash_change = hash[:cash] - @previous_standings[account][:cash]
          if nav_change > 0 and cash_change > 0 
            @wins[account] += 1 
            winners += 1
          elsif nav_change < 0 and cash_change < 0
            @losses[account] += 1 
            losers += 1
          end
          [account, {
            nav_change: nav_change.money,
            cash_change: cash_change.money,
            wins: @wins[account] || 0,
            losses: @losses[account] || 0,
            nav: hash[:nav].money
          }]
        end
      ]
      Hash[movement.sort_by { |a, h| h[:wins] - h[:losses] }].each_pair do |account, hash|
        ap [account, hash], multiline: false
      end
      puts "#{winners} winners and #{losers} losers"
    end
    @previous_stock_price = @last
    @previous_standings = @standings unless @standings.empty?
  end

  def watch_account account
    uri  = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{@venue}/executions/stocks/#{@stock}"
    fills = Faye::WebSocket::Client.new(uri)
    dummy_bot = Bot.new APIKEY, account, @venue, @stock
    dummy_bot.silent = true
    @spying[account] = { bot: dummy_bot, socket: fills }
  end

  def unwatch_account account
    @spying.delete account
  end

  def account_status account
    bot = @spying[account][:bot]
    trade_count = @accounts[account]
    data = {
      account: account,
      nav: bot.nav.money,
      shares: bot.shares_held,
      cash: bot.cash.money,
      trades: trade_count
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

  def spy_top_accounts count=5
    top = @accounts.each_pair.to_a.sort { |a,b| a[1] <=> b[1] }.first(count).map { |pair| pair[0] }
    top.each do |a|
      watch_account a
    end
  end
  
  def accounts_harvested
    @accounts.keys.size
  end

  def accounts_spying
    @spying.keys.size
  end

  private

  def is_account_number? string
    !string.start_with? "order"
  end
end

EM.run do
  quotes_uri = "wss://api.stockfighter.io/ob/api/ws/#{account}/venues/#{venue}/tickertape/stocks/#{stock}"
  quotes = Faye::WebSocket::Client.new(quotes_uri)
  trader = Trader.new APIKEY, account, venue, stock

  EM.add_periodic_timer(8) do
    trader.harvest_account_numbers(100) unless trader.accounts_harvested > 80
    if trader.accounts_spying == 0 && trader.accounts_harvested > 80
      puts "rigging up spy machine..."
      trader.spy_top_accounts(50)
      trader.spying.each do |account, hash|
        hash[:socket].on :message do |event|
          data = JSON.load(event.data)
          hash[:bot].update_position_with data
          print "-"
        end
      end
    end
  end

  EM.add_periodic_timer(5) do
    trader.winners_report
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

