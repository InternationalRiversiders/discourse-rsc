# frozen_string_literal: true
module DiscourseRsc
  class Risk
    def self.lock(user_id)
      Commands.lock("rsc-portfolio:#{user_id}")
      Account.wallet(user_id).lock!
    end

    def self.check!(user_id, instrument, leverage, margin, excluding_order: nil)
      return unless instrument.category == "crypto" || TradingRules.delayed?(instrument)
      return if leverage <= 10 && !SiteSetting.rsc_standard_position_limits_enabled
      positions, pending, equity = portfolio(user_id, excluding_order: excluding_order)
      if leverage > 10
        raise Error.new("high_risk_disabled", status: 403) unless SiteSetting.rsc_high_risk_enabled
        unless positions.any? { |p| p.instrument_id == instrument.id && p.leverage > 10 }
          raise Error.new("high_risk_cooldown", status: 429) if high_risk_cooldown_until(user_id)
        end
        budget = high_risk_budget(positions, pending, equity)
        raise Error.new("high_risk_budget", status: 409) if margin > budget[:available_margin]
        return
      end
      crypto_market = instrument.category == "crypto"
      crypto = positions.select { |p| crypto_market ? p.instrument.category == "crypto" : TradingRules.delayed?(p.instrument) }
      crypto_orders = pending.select { |o| crypto_market ? o.instrument.category == "crypto" : TradingRules.delayed?(o.instrument) }
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

    # One shared high-risk budget replaces per-symbol, symbol-count and weighted
    # caps. Ordinary positions do not consume it; all positions inform equity.
    def self.portfolio(user_id, excluding_order: nil)
      positions = Position.where(user_id: user_id).includes(:instrument).to_a
      pending = Order.where(user_id: user_id, status: "pending").where.not(side: "close").includes(:instrument).to_a
      equity = Account.wallet_snapshot(user_id).balance_units.to_i + pending.sum { |o| o.reserved_units.to_i }
      pending_dividends = Dividend.where(status: "approved").where("effective_at <= ?", Time.current).pluck(:instrument_id)
      positions.each do |position|
        next if pending_dividends.include?(position.instrument_id)
        begin
          equity += [position.margin_units.to_i + Exchange.pnl(position, Exchange.price!(position.instrument)), 0].max
        rescue Error
          # An unpriced position contributes zero to available risk capital.
          # This permits crypto trading over a stock-market weekend without
          # inventing a current valuation or borrowing against stale gains.
        end
      end
      pending.reject! { |o| o.id == excluding_order }
      [positions, pending, equity]
    end

    def self.high_risk_budget(positions, pending, equity)
      high_positions = positions.select { |p| p.instrument.category == "crypto" && p.leverage > 10 }
      high_orders = pending.select { |p| p.instrument.category == "crypto" && p.leverage > 10 }
      used = high_positions.sum { |p| TradingRules.initial_margin(p) } + high_orders.sum { |p| TradingRules.order_margin(p) }
      maximum = equity * SiteSetting.rsc_high_risk_margin_percent / 100
      { equity: equity, maximum_margin: maximum, used_margin: used, available_margin: [maximum - used, 0].max }
    end

    # Read-only status for the order ticket; execution still checks under lock.
    def self.high_risk_cooldown_until(user_id)
      seconds = SiteSetting.rsc_high_risk_cooldown_seconds
      return if seconds.zero?
      closed_at = Order.where(user_id: user_id, side: "close", status: "filled")
        .where("leverage > 10 AND updated_at > ?", seconds.seconds.ago).maximum(:updated_at)
      closed_at && closed_at + seconds.seconds
    end

    # Evaluate current policy for existing positions as well as newly filled
    # orders. Do not carry legacy five/two-minute locks across this release.
    # The original lock starts at submission; changing policy never alters cost.
    def self.hold_until(position)
      return unless position.instrument.category == "crypto" && position.leverage > 10 && SiteSetting.rsc_high_risk_hold_seconds.positive?
      opened_at = Order.where(user_id: position.user_id, instrument_id: position.instrument_id, side: position.side, status: "filled").maximum(:created_at)
      (opened_at || position.created_at) + SiteSetting.rsc_high_risk_hold_seconds.seconds
    end

    def self.high_risk_status(user_id)
      positions = Position.where(user_id: user_id).where("leverage > 10").includes(:instrument).select { |p| p.instrument.category == "crypto" }
      pending = Order.where(user_id: user_id, status: "pending").where.not(side: "close")
        .where("leverage > 10").includes(:instrument).select { |p| p.instrument.category == "crypto" }
      budget = high_risk_budget(*portfolio(user_id)).transform_values { |value| Amount.format(value) }
      { budget: budget, margin_percent: SiteSetting.rsc_high_risk_margin_percent, cooldown_until: high_risk_cooldown_until(user_id),
        positions: positions.map { |p| { instrument_id: p.instrument_id, symbol: p.instrument.symbol, hold_until: hold_until(p) } },
        pending: pending.map { |p| { instrument_id: p.instrument_id, symbol: p.instrument.symbol } } }
    end

    def self.weighted(margin, leverage)
      bps = leverage <= 1 ? 10_000 : (leverage <= 5 ? 8000 : 5000)
      (margin * 10_000 + bps - 1) / bps
    end

    def self.daily!(user_id, instrument, side: "long")
      return unless instrument.category == "crypto" && side != "close"
      total_limit = SiteSetting.rsc_crypto_daily_open_limit
      symbol_limit = SiteSetting.rsc_crypto_symbol_daily_open_limit
      return if total_limit.zero? && symbol_limit.zero?
      day = (Time.current.utc + 8.hours).to_date
      starts = Time.utc(day.year, day.month, day.day) - 8.hours
      orders = Order.joins(:instrument).where(user_id: user_id, created_at: starts...(starts + 1.day), status: %w[pending filled canceled], side: %w[long short]).where(discourse_rsc_instruments: { category: "crypto" })
      raise Error.new("crypto_daily_limit", status: 429) if (total_limit.positive? && orders.count >= total_limit) || (symbol_limit.positive? && orders.where(instrument_id: instrument.id).count >= symbol_limit)
    end

    def self.liquidation(position)
      distance = position.margin_units.to_i * 3 * Amount::UNIT / (4 * position.quantity_units.to_i)
      adjustment = position.dividend_units.to_i * Amount::UNIT / position.quantity_units.to_i
      value = position.side == "long" ? position.average_units.to_i - distance - adjustment : position.average_units.to_i + distance + adjustment
      Amount.format([value, 0].max)
    end
  end
end
