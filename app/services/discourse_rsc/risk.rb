# frozen_string_literal: true
module DiscourseRsc
  class Risk
    def self.lock(user_id)
      Commands.lock("rsc-portfolio:#{user_id}")
      Account.wallet(user_id).lock!
    end

    def self.check!(user_id, instrument, leverage, margin, excluding_order: nil)
      return unless instrument.category == "crypto" || TradingRules.delayed?(instrument)
      positions = Position.where(user_id: user_id).includes(:instrument).to_a
      pending = Order.where(user_id: user_id, status: "pending").where.not(side: "close").includes(:instrument).to_a
      equity = Account.wallet(user_id).balance_units.to_i + pending.sum { |o| o.reserved_units.to_i }
      positions.each do |position|
        begin
          equity += [position.margin_units.to_i + Exchange.pnl(position, Exchange.price!(position.instrument)), 0].max
        rescue Error
          # An unpriced position contributes zero to available risk capital.
          # This permits crypto trading over a stock-market weekend without
          # inventing a current valuation or borrowing against stale gains.
        end
      end
      pending.reject! { |o| o.id == excluding_order }
      crypto_market = instrument.category == "crypto"
      crypto = positions.select { |p| crypto_market ? p.instrument.category == "crypto" : TradingRules.delayed?(p.instrument) }
      crypto_orders = pending.select { |o| crypto_market ? o.instrument.category == "crypto" : TradingRules.delayed?(o.instrument) }
      if leverage > 10
        raise Error.new("high_risk_disabled", status: 403) unless SiteSetting.rsc_high_risk_enabled
        raise Error.new("high_risk_position_limit", status: 409) if (crypto + crypto_orders).any? { |p| p.leverage > 10 && p.instrument_id != instrument.id }
        unless crypto.any? { |p| p.instrument_id == instrument.id && p.leverage > 10 }
          recent = high_risk_cooldown_until(user_id)
          raise Error.new("high_risk_cooldown", status: 429) if recent
        end
      end
      existing = crypto.select { |p| p.instrument_id == instrument.id }.sum { |p| TradingRules.initial_margin(p) }
      existing += crypto_orders.select { |p| p.instrument_id == instrument.id }.sum { |p| TradingRules.order_margin(p) }
      single_bps = leverage <= 1 ? 10_000 : (leverage <= 5 ? 5000 : 2500)
      raise Error.new("position_risk_limit", status: 409) if (existing + margin) * 10_000 > equity * single_bps
      risk = (crypto + crypto_orders).sum do |p|
        value = p.is_a?(Position) ? TradingRules.initial_margin(p) : TradingRules.order_margin(p)
        weighted(value, p.leverage)
      end + weighted(margin, leverage)
      raise Error.new("portfolio_risk_limit", status: 409) if risk > equity
    end

    # Read-only status for the order ticket; execution still checks under lock.
    def self.high_risk_cooldown_until(user_id)
      closed_at = Order.where(user_id: user_id, side: "close", status: "filled")
        .where("leverage > 10 AND updated_at > ?", 30.minutes.ago).maximum(:updated_at)
      closed_at && closed_at + 30.minutes
    end

    def self.high_risk_status(user_id)
      positions = Position.where(user_id: user_id).where("leverage > 10").includes(:instrument).select { |p| p.instrument.category == "crypto" }
      pending = Order.where(user_id: user_id, status: "pending").where.not(side: "close")
        .where("leverage > 10").includes(:instrument).select { |p| p.instrument.category == "crypto" }
      { cooldown_until: high_risk_cooldown_until(user_id),
        positions: positions.map { |p| { instrument_id: p.instrument_id, symbol: p.instrument.symbol, hold_until: p.hold_until } },
        pending: pending.map { |p| { instrument_id: p.instrument_id, symbol: p.instrument.symbol } } }
    end

    def self.weighted(margin, leverage)
      bps = leverage <= 1 ? 10_000 : (leverage <= 5 ? 8000 : 5000)
      (margin * 10_000 + bps - 1) / bps
    end

    def self.daily!(user_id, instrument)
      return unless instrument.category == "crypto"
      day = (Time.current.utc + 8.hours).to_date
      starts = Time.utc(day.year, day.month, day.day) - 8.hours
      orders = Order.joins(:instrument).where(user_id: user_id, created_at: starts...(starts + 1.day), status: %w[pending filled canceled]).where(discourse_rsc_instruments: { category: "crypto" })
      raise Error.new("crypto_daily_limit", status: 429) if orders.count >= 20 || orders.where(instrument_id: instrument.id).count >= 10
    end

    def self.liquidation(position)
      distance = position.margin_units.to_i * 3 * Amount::UNIT / (4 * position.quantity_units.to_i)
      value = position.side == "long" ? position.average_units.to_i - distance : position.average_units.to_i + distance
      Amount.format([value, 0].max)
    end
  end
end
