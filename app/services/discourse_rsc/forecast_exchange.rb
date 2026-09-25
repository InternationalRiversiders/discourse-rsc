# frozen_string_literal: true
module DiscourseRsc
  module ForecastExchange
    UNIT = Amount::UNIT
    LOT = UNIT / 1_000_000
    MAX_ORDER = 500 * UNIT
    MAX_USER_SHARES = 2_000 * UNIT
    MAX_MARKET_SHARES = 20_000 * UNIT

    def self.enabled!
      raise Error.new('forecast_disabled', status: 404) unless SiteSetting.rsc_forecast_enabled && SiteSetting.rsc_native_trial_enabled
    end

    def self.open!(market)
      raise Error.new('forecast_closed', status: 409) unless market.state == 'open' && market.ends_at > Time.current && market.synced_at && market.synced_at >= 60.seconds.ago
    end

    # Buy uses an RSC budget; sell uses shares. Fill against all price levels,
    # charging rounded-up atomic cash for buys and rounded-down cash for sells.
    # A quote must be fully executable; never silently fill only part of an order.
    def self.fill(book, side, amount)
      levels = Array(book[side == 'buy' ? 'asks' : 'bids']).map do |row|
        p = ForecastProvider.decimal(row.fetch('price'))
        s = ForecastProvider.decimal(row.fetch('size'))
        raise ArgumentError unless p >= 0 && p <= 1 && s > 0
        [(p * UNIT).to_i, (s * UNIT).to_i / LOT * LOT]
      end
      levels.select! { |price, size| price > 0 && price < UNIT && size > 0 }
      levels.sort_by!(&:first)
      if side == 'buy' && levels.first && !levels.first[0].between?(UNIT / 50, UNIT * 98 / 100)
        raise Error.new('forecast_liquidity', status: 409)
      end
      levels.reverse! if side == 'sell'
      left = amount; shares = 0; cash = 0
      levels.each do |price, size|
        # Ignore negligible tails. Buying outside these bounds remains unavailable.
        next if side == 'buy' && !price.between?(UNIT / 50, UNIT * 98 / 100)
        quantity = side == 'buy' ? [size, left * UNIT / price / LOT * LOT].min : [size, left].min
        next unless quantity.positive?
        value = side == 'buy' ? (quantity * price + UNIT - 1) / UNIT : quantity * price / UNIT
        shares += quantity; cash += value
        left -= side == 'buy' ? value : quantity
        break if left.zero? || (side == 'buy' && left < LOT)
      end
      raise Error.new('forecast_liquidity', status: 409) unless shares.positive? && cash.positive? && (side == 'buy' ? left < LOT : left.zero?)
      [shares, cash]
    rescue ArgumentError, TypeError, KeyError
      raise Error.new('forecast_unavailable', status: 503)
    end

    def self.quote(actor:, market_id:, outcome:, side:, amount:)
      enabled!
      Access.ensure_member!(actor)
      Safety.ensure_writable!
      raise Error.new('invalid_amount') unless %w[buy sell].include?(side) && [0, 1].include?(outcome)
      units = Amount.positive(amount, decimals: 6)
      raise Error.new('forecast_limit', status: 409) if (side == 'buy' && (units < UNIT || units > MAX_ORDER)) || (side == 'sell' && units > MAX_USER_SHARES)
      market = ForecastMarket.find(market_id)
      ForecastProvider.refresh(market)
      open!(market)
      # Closed=false alone is insufficient: a proposed result also stops trading.
      resolution = ForecastProvider.resolution(market)
      ForecastSettlement.observe(market, resolution) if resolution
      market.reload
      open!(market)
      book = ForecastProvider.book(market, outcome)
      shares, cash = fill(book, side, units)
      ForecastMarket.transaction do
        market.lock!
        open!(market)
        holding = ForecastPosition.find_by(market_id: market.id, user_id: actor.id, outcome: outcome)
        if side == 'sell'
          raise Error.new('forecast_shares', status: 409) unless holding && holding.state == 'open' && holding.shares_units >= shares
        else
          raise Error.new('insufficient_balance', status: 409) if Account.wallet_snapshot(actor.id).balance_units < cash
        end
        # A new quote supersedes old quotes for this member.
        ForecastQuote.where(user_id: actor.id, used_at: nil).where('expires_at > ?', Time.current).update_all(expires_at: Time.current)
        item = ForecastQuote.create!(market_id: market.id, user_id: actor.id, token: SecureRandom.hex(24), outcome: outcome, side: side,
          shares_units: shares, cash_units: cash, terms_digest: market.terms_digest, expires_at: 15.seconds.from_now)
        quote_view(item)
      end
    end

    def self.quote_view(item)
      { token: item.token, side: item.side, outcome: item.outcome, shares: Amount.format(item.shares_units),
        cash: Amount.format(item.cash_units), average: Amount.format(item.cash_units.to_i * UNIT / item.shares_units.to_i),
        multiple: Amount.format(item.shares_units.to_i * UNIT / item.cash_units.to_i),
        potential_payout: Amount.format(item.shares_units), expires_at: item.expires_at }
    end

    def self.execute(actor:, token:, request_id:)
      enabled!
      Access.ensure_member!(actor)
      Commands.run(user_id: actor.id, action: 'forecast_trade', request_id: request_id, input: [token]) do
        # All trades and settlements lock market, then quote/position, then ledger.
        quote = ForecastQuote.find_by!(token: token, user_id: actor.id)
        market = ForecastMarket.lock.find(quote.market_id)
        quote.lock!
        open!(market)
        raise Error.new('forecast_quote_expired', status: 409) if quote.used_at || quote.expires_at <= Time.current || quote.terms_digest != market.terms_digest
        wallet = Account.wallet(actor.id)
        raise Error.new('wallet_frozen', status: 403) unless wallet.status == 'active'
        position = ForecastPosition.lock.find_or_create_by!(market_id: market.id, user_id: actor.id, outcome: quote.outcome)
        shares, cash = quote.shares_units.to_i, quote.cash_units.to_i
        escrow = Account.internal("forecast:#{position.id}")
        bank = Account.internal('system:forecast', kind: 'system')
        pnl = 0
        if quote.side == 'buy'
          user_shares = ForecastPosition.where(market_id: market.id, user_id: actor.id, state: 'open').sum(:shares_units).to_i
          all_shares = ForecastPosition.where(market_id: market.id, state: 'open').sum(:shares_units).to_i
          raise Error.new('forecast_limit', status: 409) if user_shares + shares > MAX_USER_SHARES || all_shares + shares > MAX_MARKET_SHARES
          postings = { wallet.id => -cash, escrow.id => cash }
          position.update!(shares_units: position.shares_units.to_i + shares, cost_units: position.cost_units.to_i + cash, state: 'open')
        else
          raise Error.new('forecast_shares', status: 409) unless position.state == 'open' && position.shares_units >= shares
          cost = position.cost_units.to_i * shares / position.shares_units.to_i
          pnl = cash - cost
          postings = { wallet.id => cash, escrow.id => -cost, bank.id => cost - cash }
          position.update!(shares_units: position.shares_units.to_i - shares, cost_units: position.cost_units.to_i - cost,
            realized_units: position.realized_units.to_i + pnl)
        end
        journal = Commands.move(user_id: actor.id, action: "forecast_#{quote.side}", request_id: request_id, postings: postings,
          metadata: { forecast_market_id: market.id, question: market.question, outcome: market.outcomes[quote.outcome], shares: Amount.format(shares) })
        trade = ForecastTrade.create!(market_id: market.id, user_id: actor.id, journal_id: journal.id, outcome: quote.outcome, side: quote.side,
          shares_units: shares, cash_units: cash, pnl_units: pnl)
        quote.update!(used_at: Time.current)
        { trade_id: trade.id, balance: wallet.reload.balance }
      end
    end
  end
end
