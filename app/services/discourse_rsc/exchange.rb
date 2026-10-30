# frozen_string_literal: true
module DiscourseRsc
  # Native trial exchange. Quotes are supplied by trusted server-side adapters;
  # public endpoints never accept prices, payouts, or liquidation decisions.
  class Exchange
    U = Amount::UNIT

    def self.submit(actor:, instrument_id:, side:, quantity:, leverage:, request_id:, high_risk: false, take_profit: nil, stop_loss: nil, cancel_pending: false)
      Access.ensure_member!(actor)
      raise Error.new("invalid_order") unless %w[long short close].include?(side) && leverage.is_a?(Integer) && leverage.between?(1, 100)
      units = Amount.positive(quantity)
      tp = take_profit.present? ? Amount.positive(take_profit) : nil
      sl = stop_loss.present? ? Amount.positive(stop_loss) : nil
      Safety.ensure_writable!
      unless Command.exists?(key: "stock_submit:#{actor.id}:#{request_id}")
        MarketData.refresh_if_needed(instrument_id, purpose: side == "close" ? :exit : :trade)
      end
      input = [instrument_id, side, units.to_s, leverage, high_risk, tp&.to_s, sl&.to_s]
      input << { cancel_pending: true } if cancel_pending
      Commands.run(user_id: actor.id, action: "stock_submit", request_id: request_id, input: input) do
        Commands.lock("rsc-exchange")
        instrument = Instrument.lock.find(instrument_id)
        Risk.lock(actor.id)
        if side != "close" && leverage > 10 && (!(instrument.category == "crypto" || ForexActivity.active_for?(instrument)) || !high_risk || !SiteSetting.rsc_high_risk_enabled)
          raise Error.new("high_risk_disabled", status: 403)
        end
        Risk.daily!(actor.id, instrument, side: side)
        waiting_quote = false
        price = begin
          price!(instrument, trading: true)
        rescue Error => error
          raise unless forex_exit?(instrument, side) && instrument.active && %w[quote_stale quote_unavailable quote_verifying].include?(error.code)
          raise Error.new("market_closed", status: 409) if MarketSessions.closed?(instrument)
          waiting_quote = true
          nil
        end
        raise Error.new("invalid_quantity") unless units >= instrument.minimum_units && (units % instrument.step_units.to_i).zero?
        pending = Order.where(user_id: actor.id, instrument_id: instrument.id, status: "pending").order(:id).lock.to_a
        replacing = side == "close" && cancel_pending && pending.all? { |order| order.side != "close" }
        raise Error.new("order_pending", status: 409) if pending.any? && !replacing
        raise Error.new("too_many_orders") if side != "close" && Order.where(user_id: actor.id, status: "pending").where.not(side: "close").count >= 10
        position = Position.find_by(user_id: actor.id, instrument_id: instrument.id)
        if side == "close"
          raise Error.new("position_unavailable") unless position && position.quantity_units >= units
          hold_until = Risk.hold_until(position)
          raise Error.new("position_locked", status: 409) if hold_until && hold_until > Time.current
          leverage = position.leverage
          pending.each { |order| refund_locked(order, "canceled") } if replacing
        elsif position && (position.side != side || position.leverage != leverage)
          raise Error.new("position_conflict", status: 409)
        end
        wallet = Account.wallet(actor.id)
        raise Error.new("wallet_frozen", status: 403) unless wallet.status == "active"
        delay = instrument.quote.fetch("delay_seconds", 0).to_i
        fx_confirmation = ForexActivity.confirmation?(instrument, leverage) && side != "close"
        delayed = instrument.category == "crypto" || TradingRules.delayed?(instrument) || fx_confirmation || waiting_quote
        fee_bps = ForexActivity.fee_bps(instrument, position: position)
        wait = instrument.category == "crypto" ? (side == "close" ? 0 : SiteSetting.rsc_crypto_confirmation_delay_seconds) : [[delay - 30, 30].max, 1800].min
        wait = 0 if waiting_quote || (fx_confirmation && !TradingRules.delayed?(instrument))
        order = Order.create!(user_id: actor.id, instrument_id: instrument.id, side: side, leverage: leverage,
                              status: delayed ? "pending" : "executing", quantity_units: units,
                              execute_at: Time.current + wait.seconds, expires_at: Time.current + (instrument.category == "crypto" ? 15 : 30).minutes,
                              details: { "reference_price" => price && Amount.format(price), "delayed" => TradingRules.delayed?(instrument), "take_profit" => tp && Amount.format(tp), "stop_loss" => sl && Amount.format(sl) }.merge(ForexActivity.order_details(instrument, position, side)).merge("fee_bps" => fee_bps, "fx_confirmation" => fx_confirmation, "waiting_quote" => waiting_quote, "position_id" => side == "close" ? position.id : nil))
        if side != "close"
          gross = units * price / U
          TradingRules.opening!(instrument, gross)
          if tp || sl
            projected = Position.new(side: side, average_units: ((position&.quantity_units.to_i || 0) * (position&.average_units.to_i || 0) + units * price) / ((position&.quantity_units.to_i || 0) + units), quantity_units: (position&.quantity_units.to_i || 0) + units, margin_units: (position&.margin_units.to_i || 0) + ceil_div(gross, leverage), leverage: leverage)
            TradingRules.protection!(projected, instrument, price, tp, sl, fee_bps: fee_bps)
          end
          # Reserve at the upper edge of the 5% execution band, including fees.
          reserve = ceil_div(gross * 105, 100 * leverage) + ceil_div(gross * 105 * fee_bps, 1_000_000)
          unless delayed
            immediate_gross = units * execution_price(instrument, side, price) / U
            reserve = ceil_div(immediate_gross, leverage) + immediate_gross * fee_bps / 10_000
          end
          Risk.check!(actor.id, instrument, leverage, ceil_div(gross, leverage), excluding_order: order.id)
          Commands.move(user_id: actor.id, action: "stock_reserve", request_id: "order-reserve-#{order.id}",
                        postings: { wallet.id => -reserve, Account.internal("order:#{order.id}").id => reserve }, metadata: { order_id: order.id })
          order.update!(reserved_units: reserve)
        end
        unless delayed
          side == "close" ? close_locked(instrument, order, position, price, "stock_closed") : open_locked(instrument, order, position, price)
        end
        { order_id: order.id, status: order.status, waiting_quote: waiting_quote }
      end
    end

    def self.cancel(actor:, order_id:, request_id:)
      Access.ensure_member!(actor)
      Commands.run(user_id: actor.id, action: "stock_cancel", request_id: request_id, input: [order_id]) do
        candidate = Order.find_by!(id: order_id, user_id: actor.id)
        Commands.lock("rsc-exchange")
        instrument = Instrument.lock.find(candidate.instrument_id)
        Risk.lock(actor.id)
        order = Order.lock.find(candidate.id)
        raise Error.new("order_not_pending", status: 409) unless order.status == "pending"
        window_open = instrument.category == "crypto" || forex_exit?(instrument, order.side) || order.details["fx_confirmation"] || Time.current <= order.created_at + 10.seconds
        unless window_open || order.expires_at <= Time.current || instrument.provider_error.present? || order.details["error"].present?
          raise Error.new("cancellation_locked", status: 409)
        end
        refund_locked(order, "canceled")
        { order_id: order.id, status: order.status }
      end
    end

    def self.protect(actor:, position_id:, take_profit:, stop_loss:, request_id:)
      Access.ensure_member!(actor)
      tp = take_profit.present? ? Amount.positive(take_profit) : nil
      sl = stop_loss.present? ? Amount.positive(stop_loss) : nil
      Safety.ensure_writable!
      unless Command.exists?(key: "stock_protect:#{actor.id}:#{request_id}")
        candidate = Position.find_by!(id: position_id, user_id: actor.id)
        MarketData.refresh_if_needed(candidate.instrument_id, purpose: :protection)
      end
      Commands.run(user_id: actor.id, action: "stock_protect", request_id: request_id, input: [position_id, tp&.to_s, sl&.to_s]) do
        candidate = Position.find_by!(id: position_id, user_id: actor.id)
        Commands.lock("rsc-exchange")
        instrument = Instrument.lock.find(candidate.instrument_id)
        position = Position.lock.find(candidate.id)
        Risk.lock(actor.id)
        raise Error.new("wallet_frozen", status: 403) unless Account.wallet(actor.id).status == "active"
        price = price!(instrument)
        TradingRules.protection!(position, instrument, price, tp, sl, fee_bps: ForexActivity.fee_bps(instrument, position: position))
        position.update!(take_profit_units: tp, stop_loss_units: sl)
        { position_id: position.id }
      end
    end

    def self.process(instrument_id)
      Safety.ensure_writable!
      Instrument.transaction do
        Commands.lock("rsc-exchange")
        instrument = Instrument.lock.find(instrument_id)
        Order.where(instrument_id: instrument.id, status: "pending").where("expires_at <= ?", Time.current).order(:id).each { |order| refund_locked(order, "expired") }
        # Activity expiry must release reservations even with a stale/closed feed,
        # and must not wait for a delayed order's execution window.
        if instrument.category == 'forex' && !ForexActivity.active?
          Order.where(instrument_id: instrument.id, status: 'pending').where.not(side: 'close')
            .where("details->>'forex_campaign' = ? OR leverage > 10", ForexActivity::KEY).order(:id).each do |order|
              Risk.lock(order.user_id)
              refund_locked(order, 'expired', 'forex_activity_ended')
            end
        end
        begin
          price = price!(instrument, trading: true)
        rescue Error
          next
        end
        Position.where(instrument_id: instrument.id).order(:id).each do |position|
          Risk.lock(position.user_id)
          next unless Account.wallet(position.user_id).status == "active"
          equity = position.margin_units.to_i + pnl(position, price)
          long = position.side == "long"
          kind = if equity <= position.margin_units.to_i / 4
            "stock_liquidated"
          elsif position.stop_loss_units && (long ? price <= position.stop_loss_units : price >= position.stop_loss_units)
            "stock_stop_loss"
          elsif position.take_profit_units && (long ? price >= position.take_profit_units : price <= position.take_profit_units)
            "stock_take_profit"
          end
          next unless kind
          Order.where(user_id: position.user_id, instrument_id: instrument.id, status: "pending").each { |order| refund_locked(order, "canceled") }
          order = Order.create!(user_id: position.user_id, instrument_id: instrument.id, side: "close", leverage: position.leverage,
                                status: "executing", quantity_units: position.quantity_units, details: { "automatic" => true })
          close_locked(instrument, order, position, price, kind)
        end
        Order.where(instrument_id: instrument.id, status: "pending").where("execute_at <= ?", Time.current).order(:id).each do |order|
          Risk.lock(order.user_id)
          # Opening requires a post-submission quote. Non-delayed FX exits
          # may use the already validated live quote, including pre-upgrade orders.
          next unless forex_exit?(instrument, order.side) || Time.iso8601(instrument.quote.fetch("source_time")) > order.created_at
          reference = order.details["reference_price"] && Amount.parse(order.details["reference_price"])
          if !order.details["waiting_quote"] && reference && (price - reference).abs * 100 > reference * 5
            refund_locked(order, "rejected", "price_moved")
            next
          end
          position = Position.find_by(user_id: order.user_id, instrument_id: instrument.id)
          if Account.wallet(order.user_id).status != "active" || (order.side == "close" && (!position || position.quantity_units < order.quantity_units || (order.details["position_id"] && order.details["position_id"].to_i != position.id)))
            refund_locked(order, "rejected", Account.wallet(order.user_id).status != "active" ? "wallet_frozen" : "position_unavailable")
          elsif order.side == "close"
            close_locked(instrument, order, position, price, "stock_closed")
          else
            begin
              TradingRules.opening!(instrument, order.quantity_units.to_i * price / U)
              Risk.check!(order.user_id, instrument, order.leverage, ceil_div(order.quantity_units.to_i * price / U, order.leverage), excluding_order: order.id)
              open_locked(instrument, order, position, price)
            rescue Error => error
              raise unless %w[position_risk_limit portfolio_risk_limit high_risk_budget high_risk_cooldown high_risk_position_limit high_risk_disabled forex_activity_ended quote_stale quote_unavailable market_opening_disabled order_notional_below_min market_liquidity_limit invalid_protection take_profit_not_profitable stop_loss_beyond_liquidation].include?(error.code)
              refund_locked(order, "rejected", error.code)
            end
          end
        end
      end
    end

    def self.add_margin(actor:, position_id:, amount:, request_id:)
      Access.ensure_member!(actor)
      units = Amount.positive(amount)
      Commands.run(user_id: actor.id, action: "stock_margin", request_id: request_id, input: [position_id, units.to_s]) do
        candidate = Position.find_by!(id: position_id, user_id: actor.id)
        Commands.lock("rsc-exchange")
        instrument = Instrument.lock.find(candidate.instrument_id)
        Risk.lock(actor.id)
        position = Position.lock.find(candidate.id)
        raise Error.new("wallet_frozen", status: 403) unless Account.wallet(actor.id).status == "active"
        Commands.move(user_id: actor.id, action: "stock_margin", request_id: request_id,
                      postings: { Account.wallet(actor.id).id => -units, Account.internal("position:#{position.id}").id => units }, metadata: { position_id: position.id })
        ForexActivity.prepare_close(position) if instrument.category == "forex"
        position.update!(margin_units: position.margin_units.to_i + units)
        { position_id: position.id, margin: Amount.format(position.margin_units) }
      end
    end

    def self.price!(instrument, trading: false)
      quote = instrument.quote
      raise Error.new('quote_verifying', status: 409) if instrument.category == 'forex' && ForexQuoteGuard.pending?(quote)
      if trading && MarketData.forex_base(instrument) && quote["pricing_method"] != MarketData::FX_PRICING
        raise Error.new("quote_stale", status: 409)
      end
      raise Error.new("quote_stale", status: 409) if quote["legacy_snapshot"]
      raise Error.new("quote_unavailable", status: 409) unless instrument.active && quote["price"] && quote["received_at"] && quote["source_time"]
      now = Time.current
      raise Error.new("market_closed", status: 409) if trading && instrument.category != "crypto" && MarketSessions.closed?(instrument, now)
      received = Time.iso8601(quote["received_at"])
      source = Time.iso8601(quote["source_time"])
      delay = quote.fetch("delay_seconds", 0).to_i
      raise Error.new("quote_stale", status: 409) if received < now - 120.seconds || received > now + 5.seconds || source > now + 5.seconds || source < now - (delay + ForexQuoteGuard.max_age(quote)).seconds
      if trading && instrument.category != "crypto"
        raise Error.new("market_closed", status: 409) if MarketSessions.closed?(instrument, now)
        raise Error.new("market_closed", status: 409) unless quote["session_start"] && quote["session_end"] && now >= Time.iso8601(quote["session_start"]) && now < Time.iso8601(quote["session_end"])
      end
      Amount.positive(quote["price"])
    rescue ArgumentError, KeyError
      raise Error.new("quote_unavailable", status: 409)
    end

    def self.pnl(position, price, quantity = position.quantity_units.to_i)
      value = quantity * (price - position.average_units.to_i) / U
      position.side == "long" ? value : -value
    end

    def self.ceil_div(value, divisor)
      (value + divisor - 1) / divisor
    end

    def self.open_locked(instrument, order, position, price)
      price = execution_price(instrument, order.side, price)
      quantity = order.quantity_units.to_i
      gross = quantity * price / U
      margin = ceil_div(gross, order.leverage)
      fee_bps = order.details.fetch("fee_bps", instrument.fee_bps).to_i
      if order.details["forex_campaign"] == ForexActivity::KEY && ForexActivity.active_for?(instrument)
        fee_bps = [fee_bps, SiteSetting.rsc_forex_activity_fee_bps].min
      end
      fee = gross * fee_bps / 10_000
      Risk.check!(order.user_id, instrument, order.leverage, margin, excluding_order: order.id)
      reserve = order.reserved_units.to_i
      if margin + fee > reserve || (position && (position.side != order.side || position.leverage != order.leverage))
        refund_locked(order, "rejected", margin + fee > reserve ? "insufficient_balance" : "position_conflict")
        return
      end
      tp = order.details["take_profit"] && Amount.parse(order.details["take_profit"])
      sl = order.details["stop_loss"] && Amount.parse(order.details["stop_loss"])
      order.details = order.details.merge("fee_bps" => fee_bps).merge(ForexQuoteGuard.execution_details(instrument))
      if tp || sl
        projected = Position.new(side: order.side, quantity_units: (position&.quantity_units.to_i || 0) + quantity, average_units: ((position&.quantity_units.to_i || 0) * (position&.average_units.to_i || 0) + quantity * price) / ((position&.quantity_units.to_i || 0) + quantity), margin_units: (position&.margin_units.to_i || 0) + margin, leverage: order.leverage)
        TradingRules.protection!(projected, instrument, price, tp, sl, fee_bps: fee_bps)
      end
      ForexActivity.prepare_close(position) if position && instrument.category == "forex"
      fresh_position = position.nil?
      position ||= Position.create!(user_id: order.user_id, instrument_id: instrument.id, side: order.side, leverage: order.leverage)
      existing = position.quantity_units.to_i
      position.update!(quantity_units: existing + quantity, average_units: (existing * position.average_units.to_i + quantity * price) / (existing + quantity),
                       margin_units: position.margin_units.to_i + margin, take_profit_units: tp || position.take_profit_units, stop_loss_units: sl || position.stop_loss_units,
                       hold_until: instrument.category == "crypto" && order.leverage > 10 && SiteSetting.rsc_high_risk_hold_seconds.positive? ? order.created_at + SiteSetting.rsc_high_risk_hold_seconds.seconds : nil)
      Commands.move(user_id: order.user_id, action: "stock_fill", request_id: "order-fill-#{order.id}", settlement: true,
                    postings: { Account.internal("order:#{order.id}").id => -reserve, Account.internal("position:#{position.id}").id => margin,
                                Account.internal("system:exchange", kind: "system").id => fee, Account.wallet(order.user_id).id => reserve - margin - fee },
                    metadata: { position_id: position.id, order_id: order.id, price: Amount.format(price), fee: Amount.format(fee) },
                    event: Commands.event(order.user_id, "stock_filled", { "amount" => Amount.format(margin), "symbol" => instrument.symbol, "instrument_id" => instrument.id, "order_id" => order.id }))
      ForexActivity.record_open(position, order, fee, fresh: fresh_position)
      order.update!(status: "filled", reserved_units: 0, details: order.details.merge("price" => Amount.format(price), "fee" => Amount.format(fee), "gross" => Amount.format(gross), "margin" => Amount.format(margin)))
    end

    def self.close_locked(instrument, order, position, price, kind)
      order.details = order.details.merge(ForexQuoteGuard.execution_details(instrument))
      price = execution_price(instrument, position.side == "long" ? "short" : "long", price)
      quantity = order.quantity_units.to_i
      margin = position.margin_units.to_i * quantity / position.quantity_units.to_i
      profit = pnl(position, price, quantity)
      fx_entry = ForexActivity.prepare_close(position) if instrument.category == "forex"
      fee_bps = fx_entry&.fee_bps || instrument.fee_bps
      fee = quantity * price / U * fee_bps / 10_000
      payout = [margin + profit - fee, 0].max
      Commands.move(user_id: order.user_id, action: "stock_close", request_id: "order-close-#{order.id}", settlement: true,
                    postings: { Account.internal("position:#{position.id}").id => -margin, Account.wallet(order.user_id).id => payout,
                                Account.internal("system:exchange", kind: "system").id => margin - payout },
                    metadata: { position_id: position.id, order_id: order.id, reason: kind, price: Amount.format(price), pnl: Amount.format(profit), fee: Amount.format(fee) },
                    event: Commands.event(order.user_id, kind, { "amount" => Amount.format(payout), "symbol" => instrument.symbol, "instrument_id" => instrument.id, "order_id" => order.id }))
      ForexActivity.record_close(fx_entry, position, quantity, payout - margin, kind) if fx_entry
      remaining = position.quantity_units.to_i - quantity
      remaining.zero? ? position.destroy! : position.update!(quantity_units: remaining, margin_units: position.margin_units.to_i - margin)
      ForexActivity.mark(fx_entry, remaining.zero? ? nil : position) if fx_entry
      order.update!(status: "filled", details: order.details.merge("price" => Amount.format(price), "payout" => Amount.format(payout), "pnl" => Amount.format(profit), "fee" => Amount.format(fee), "fee_bps" => fee_bps, "margin" => Amount.format(margin), "reason" => kind, "gross" => Amount.format(quantity * price / U)))
    end

    def self.execution_price(instrument, side, price)
      buy = side == "long"
      market = instrument.quote[buy ? "ask" : "bid"]
      execution = market.present? ? Amount.positive(market) : price
      if instrument.category == "crypto" && (SiteSetting.rsc_crypto_extra_slippage_enabled || !reliable_book?(instrument.quote))
        bps = 2 + SecureRandom.random_number(4)
        execution = execution * (buy ? 10_000 + bps : 10_000 - bps) / 10_000
      elsif market.blank? && instrument.category != "forex"
        # Match the legacy guard against alternating rounded stock ticks.
        recent = instrument.history.last(60).map { |point| Amount.parse(point.fetch("price")) }
        unique = recent.uniq.sort
        if recent.size >= 20 && unique.size.between?(2, 3)
          half = [unique.each_cons(2).map { |a, b| (b - a + 1) / 2 }.min, price * 50 / 10_000].min
          execution += buy ? half : -half
        end
      end
      [execution, 1].max
    end

    def self.forex_exit?(instrument, side)
      instrument.category == "forex" && side == "close" && !TradingRules.delayed?(instrument)
    end

    def self.reliable_book?(quote)
      bid = Amount.positive(quote["bid"])
      ask = Amount.positive(quote["ask"])
      bid <= ask
    rescue Error
      false
    end

    def self.refund_locked(order, status, error = nil)
      reserve = order.reserved_units.to_i
      if reserve.positive?
        Commands.move(user_id: order.user_id, action: "stock_refund", request_id: "order-refund-#{order.id}", settlement: true,
                      postings: { Account.internal("order:#{order.id}").id => -reserve, Account.wallet(order.user_id).id => reserve },
                      metadata: { order_id: order.id, status: status }, event: Commands.event(order.user_id, "stock_refunded", { "amount" => Amount.format(reserve), "instrument_id" => order.instrument_id, "order_id" => order.id, "status" => status }))
      end
      order.update!(status: status, reserved_units: 0, details: order.details.merge("error" => error, "reason" => status))
    end
    private_class_method :open_locked, :close_locked, :refund_locked, :ceil_div
  end
end
