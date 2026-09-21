# frozen_string_literal: true
module DiscourseRsc
  # Native trial exchange. Quotes are supplied by trusted server-side adapters;
  # public endpoints never accept prices, payouts, or liquidation decisions.
  class Exchange
    U = Amount::UNIT

    def self.submit(actor:, instrument_id:, side:, quantity:, leverage:, request_id:, high_risk: false, take_profit: nil, stop_loss: nil)
      Access.ensure_member!(actor)
      raise Error.new("invalid_order") unless %w[long short close].include?(side) && leverage.is_a?(Integer) && leverage.between?(1, 100)
      units = Amount.positive(quantity)
      tp = take_profit.present? ? Amount.positive(take_profit) : nil
      sl = stop_loss.present? ? Amount.positive(stop_loss) : nil
      Safety.ensure_writable!
      unless Command.exists?(key: "stock_submit:#{actor.id}:#{request_id}")
        MarketData.refresh_if_needed(instrument_id, purpose: :trade)
      end
      Commands.run(user_id: actor.id, action: "stock_submit", request_id: request_id,
                   input: [instrument_id, side, units.to_s, leverage, high_risk, tp&.to_s, sl&.to_s]) do
        Commands.lock("rsc-exchange")
        instrument = Instrument.lock.find(instrument_id)
        Risk.lock(actor.id)
        if side != "close" && leverage > 10 && (instrument.category != "crypto" || !high_risk || !SiteSetting.rsc_high_risk_enabled)
          raise Error.new("high_risk_disabled", status: 403)
        end
        Risk.daily!(actor.id, instrument)
        price = price!(instrument, trading: true)
        raise Error.new("invalid_quantity") unless units >= instrument.minimum_units && (units % instrument.step_units.to_i).zero?
        raise Error.new("order_pending", status: 409) if Order.exists?(user_id: actor.id, instrument_id: instrument.id, status: "pending")
        raise Error.new("too_many_orders") if Order.where(user_id: actor.id, status: "pending").count >= 10
        position = Position.find_by(user_id: actor.id, instrument_id: instrument.id)
        if side == "close"
          raise Error.new("position_unavailable") unless position && position.quantity_units >= units
          raise Error.new("position_locked", status: 409) if position.hold_until && position.hold_until > Time.current
          leverage = position.leverage
        elsif position && (position.side != side || position.leverage != leverage)
          raise Error.new("position_conflict", status: 409)
        end
        wallet = Account.wallet(actor.id)
        raise Error.new("wallet_frozen", status: 403) unless wallet.status == "active"
        delay = instrument.quote.fetch("delay_seconds", 0).to_i
        delayed = instrument.category == "crypto" || TradingRules.delayed?(instrument)
        wait = instrument.category == "crypto" ? (side == "close" ? 0 : SecureRandom.random_number(61) + 30) : [[delay - 30, 30].max, 1800].min
        order = Order.create!(user_id: actor.id, instrument_id: instrument.id, side: side, leverage: leverage,
                              status: delayed ? "pending" : "executing", quantity_units: units,
                              execute_at: Time.current + wait.seconds, expires_at: Time.current + (instrument.category == "crypto" ? 15 : 30).minutes,
                              details: { "reference_price" => Amount.format(price), "delayed" => TradingRules.delayed?(instrument), "take_profit" => tp && Amount.format(tp), "stop_loss" => sl && Amount.format(sl) })
        if side != "close"
          gross = units * price / U
          TradingRules.opening!(instrument, gross)
          if tp || sl
            projected = Position.new(side: side, average_units: ((position&.quantity_units.to_i || 0) * (position&.average_units.to_i || 0) + units * price) / ((position&.quantity_units.to_i || 0) + units), quantity_units: (position&.quantity_units.to_i || 0) + units, margin_units: (position&.margin_units.to_i || 0) + ceil_div(gross, leverage), leverage: leverage)
            TradingRules.protection!(projected, instrument, price, tp, sl)
          end
          # Reserve at the upper edge of the 5% execution band, including fees.
          reserve = ceil_div(gross * 105, 100 * leverage) + ceil_div(gross * 105 * instrument.fee_bps, 1_000_000)
          unless delayed
            immediate_gross = units * execution_price(instrument, side, price) / U
            reserve = ceil_div(immediate_gross, leverage) + immediate_gross * instrument.fee_bps / 10_000
          end
          Risk.check!(actor.id, instrument, leverage, ceil_div(gross, leverage), excluding_order: order.id)
          Commands.move(user_id: actor.id, action: "stock_reserve", request_id: "order-reserve-#{order.id}",
                        postings: { wallet.id => -reserve, Account.internal("order:#{order.id}").id => reserve }, metadata: { order_id: order.id })
          order.update!(reserved_units: reserve)
        end
        unless delayed
          side == "close" ? close_locked(instrument, order, position, price, "stock_closed") : open_locked(instrument, order, position, price)
        end
        { order_id: order.id, status: order.status }
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
        window_open = instrument.category == "crypto" ? Time.current >= order.created_at + 2.minutes : Time.current <= order.created_at + 10.seconds
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
        MarketData.refresh_if_needed(candidate.instrument_id, purpose: :trade)
      end
      Commands.run(user_id: actor.id, action: "stock_protect", request_id: request_id, input: [position_id, tp&.to_s, sl&.to_s]) do
        candidate = Position.find_by!(id: position_id, user_id: actor.id)
        Commands.lock("rsc-exchange")
        instrument = Instrument.lock.find(candidate.instrument_id)
        position = Position.lock.find(candidate.id)
        Risk.lock(actor.id)
        raise Error.new("wallet_frozen", status: 403) unless Account.wallet(actor.id).status == "active"
        price = price!(instrument)
        TradingRules.protection!(position, instrument, price, tp, sl)
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
          # A received old quote cannot confirm a new order.
          next unless Time.iso8601(instrument.quote.fetch("source_time")) > order.created_at
          reference = Amount.parse(order.details.fetch("reference_price"))
          if (price - reference).abs * 100 > reference * 5
            refund_locked(order, "rejected", "price_moved")
            next
          end
          position = Position.find_by(user_id: order.user_id, instrument_id: instrument.id)
          if Account.wallet(order.user_id).status != "active" || (order.side == "close" && (!position || position.quantity_units < order.quantity_units))
            refund_locked(order, "rejected", Account.wallet(order.user_id).status != "active" ? "wallet_frozen" : "position_unavailable")
          elsif order.side == "close"
            close_locked(instrument, order, position, price, "stock_closed")
          else
            begin
              TradingRules.opening!(instrument, order.quantity_units.to_i * price / U)
              Risk.check!(order.user_id, instrument, order.leverage, ceil_div(order.quantity_units.to_i * price / U, order.leverage), excluding_order: order.id)
              open_locked(instrument, order, position, price)
            rescue Error => error
              raise unless %w[position_risk_limit portfolio_risk_limit high_risk_cooldown high_risk_position_limit high_risk_disabled quote_stale quote_unavailable market_opening_disabled order_notional_below_min market_liquidity_limit invalid_protection take_profit_not_profitable stop_loss_beyond_liquidation].include?(error.code)
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
        position.update!(margin_units: position.margin_units.to_i + units)
        { position_id: position.id, margin: Amount.format(position.margin_units) }
      end
    end

    def self.price!(instrument, trading: false)
      quote = instrument.quote
      raise Error.new("quote_stale", status: 409) if quote["legacy_snapshot"]
      raise Error.new("quote_unavailable", status: 409) unless instrument.active && quote["price"] && quote["received_at"] && quote["source_time"]
      now = Time.current
      received = Time.iso8601(quote["received_at"])
      source = Time.iso8601(quote["source_time"])
      delay = quote.fetch("delay_seconds", 0).to_i
      raise Error.new("quote_stale", status: 409) if received < now - 120.seconds || received > now + 5.seconds || source > now + 5.seconds || source < now - (delay + 120).seconds
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
      fee = gross * instrument.fee_bps / 10_000
      reserve = order.reserved_units.to_i
      if margin + fee > reserve || (position && (position.side != order.side || position.leverage != order.leverage))
        refund_locked(order, "rejected", margin + fee > reserve ? "insufficient_balance" : "position_conflict")
        return
      end
      tp = order.details["take_profit"] && Amount.parse(order.details["take_profit"])
      sl = order.details["stop_loss"] && Amount.parse(order.details["stop_loss"])
      if tp || sl
        projected = Position.new(side: order.side, quantity_units: (position&.quantity_units.to_i || 0) + quantity, average_units: ((position&.quantity_units.to_i || 0) * (position&.average_units.to_i || 0) + quantity * price) / ((position&.quantity_units.to_i || 0) + quantity), margin_units: (position&.margin_units.to_i || 0) + margin, leverage: order.leverage)
        TradingRules.protection!(projected, instrument, price, tp, sl)
      end
      position ||= Position.create!(user_id: order.user_id, instrument_id: instrument.id, side: order.side, leverage: order.leverage)
      existing = position.quantity_units.to_i
      position.update!(quantity_units: existing + quantity, average_units: (existing * position.average_units.to_i + quantity * price) / (existing + quantity),
                       margin_units: position.margin_units.to_i + margin, take_profit_units: tp || position.take_profit_units, stop_loss_units: sl || position.stop_loss_units,
                       hold_until: instrument.category == "crypto" ? [order.created_at + 5.minutes, position.hold_until].compact.max : (order.details["delayed"] ? Time.current + 2.minutes : position.hold_until))
      Commands.move(user_id: order.user_id, action: "stock_fill", request_id: "order-fill-#{order.id}", settlement: true,
                    postings: { Account.internal("order:#{order.id}").id => -reserve, Account.internal("position:#{position.id}").id => margin,
                                Account.internal("system:exchange", kind: "system").id => fee, Account.wallet(order.user_id).id => reserve - margin - fee },
                    metadata: { order_id: order.id, price: Amount.format(price), fee: Amount.format(fee) },
                    event: Commands.event(order.user_id, "stock_filled", { "amount" => Amount.format(margin), "symbol" => instrument.symbol, "instrument_id" => instrument.id, "order_id" => order.id }))
      order.update!(status: "filled", reserved_units: 0, details: order.details.merge("price" => Amount.format(price), "fee" => Amount.format(fee), "gross" => Amount.format(gross), "margin" => Amount.format(margin)))
    end

    def self.close_locked(instrument, order, position, price, kind)
      price = execution_price(instrument, position.side == "long" ? "short" : "long", price)
      quantity = order.quantity_units.to_i
      margin = position.margin_units.to_i * quantity / position.quantity_units.to_i
      profit = pnl(position, price, quantity)
      fee = quantity * price / U * instrument.fee_bps / 10_000
      payout = [margin + profit - fee, 0].max
      Commands.move(user_id: order.user_id, action: "stock_close", request_id: "order-close-#{order.id}", settlement: true,
                    postings: { Account.internal("position:#{position.id}").id => -margin, Account.wallet(order.user_id).id => payout,
                                Account.internal("system:exchange", kind: "system").id => margin - payout },
                    metadata: { order_id: order.id, reason: kind, price: Amount.format(price), pnl: Amount.format(profit), fee: Amount.format(fee) },
                    event: Commands.event(order.user_id, kind, { "amount" => Amount.format(payout), "symbol" => instrument.symbol, "instrument_id" => instrument.id, "order_id" => order.id }))
      remaining = position.quantity_units.to_i - quantity
      remaining.zero? ? position.destroy! : position.update!(quantity_units: remaining, margin_units: position.margin_units.to_i - margin)
      order.update!(status: "filled", details: order.details.merge("price" => Amount.format(price), "payout" => Amount.format(payout), "pnl" => Amount.format(profit), "fee" => Amount.format(fee), "margin" => Amount.format(margin), "reason" => kind, "gross" => Amount.format(quantity * price / U)))
    end

    def self.execution_price(instrument, side, price)
      buy = side == "long"
      market = instrument.quote[buy ? "ask" : "bid"]
      execution = market.present? ? Amount.positive(market) : price
      if instrument.category == "crypto"
        bps = 2 + SecureRandom.random_number(4)
        execution = execution * (buy ? 10_000 + bps : 10_000 - bps) / 10_000
      elsif market.blank?
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
