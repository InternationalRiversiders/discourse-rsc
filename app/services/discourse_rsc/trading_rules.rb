# frozen_string_literal: true
module DiscourseRsc
  # Rules shared by execution, order previews and position reporting. All prices
  # and notional amounts are integer RSC units, including FX-converted quotes.
  module TradingRules
    U = Amount::UNIT
    def self.delayed?(instrument)
      instrument.category != "crypto" && instrument.quote.fetch("delay_seconds", 0).to_i >= 120
    end

    def self.stock?(instrument)
      %w[stock etf etn fund].include?(instrument.asset_type.downcase) || %w[stock us cn hk jp eu ca au sg in].include?(instrument.category)
    end

    def self.close_only?(instrument)
      descriptor = "#{instrument.name} #{instrument.asset_type}".downcase
      packaged = %w[etf etn fund].include?(instrument.asset_type.downcase) || descriptor.match?(/\b(etf|etn|etp)\b/)
      instrument.category != "crypto" && packaged && descriptor.match?(/\b[2-9]x\b|leveraged|inverse|\bshort\b/)
    end

    def self.opening!(instrument, gross)
      raise Error.new("market_opening_disabled", status: 409) if close_only?(instrument)
      return unless stock?(instrument)
      # Imported candles are already RSC-denominated. Provider charts retain
      # their currency and must be converted using the quote's trusted FX rate.
      cache = HistoryCache.where(instrument_id: instrument.id, range: %w[1mo 6mo]).order(updated_at: :desc).first
      return unless cache
      fx_rate = instrument.quote.fetch("fx_rate", "0")
      rate = cache.currency == "RSC" || cache.currency == "USD" ? U : (fx_rate == "0" ? 0 : Amount.parse(MarketData.decimal(fx_rate)))
      return if rate.zero?
      turnovers = cache.candles.last(20).filter_map do |c|
        next unless c["volume"].present? && c["close"].present?
        value = Amount.parse(c["close"]) * Amount.parse(c["volume"]) / U * rate / U
        value if value.positive?
      rescue Error
        nil
      end.sort
      return if turnovers.size < 10
      middle = turnovers.size / 2
      median = turnovers.size.odd? ? turnovers[middle] : (turnovers[middle - 1] + turnovers[middle]) / 2
      raise Error.new("market_liquidity_limit", status: 409) if gross > median / 100
    end

    def self.break_even(position, fee_bps)
      average = position.average_units.to_i
      position.side == "short" ? average * (10_000 - fee_bps) / (10_000 + fee_bps) : (average * (10_000 + fee_bps) + 9_999 - fee_bps) / (10_000 - fee_bps)
    end

    def self.protection!(position, instrument, current_price, take_profit, stop_loss, fee_bps: instrument.fee_bps)
      long = position.side == "long"
      if current_price
        check_protection!(take_profit, current_price, above: long, field: 'take_profit', reference: 'current_price')
        check_protection!(stop_loss, current_price, above: !long, field: 'stop_loss', reference: 'current_price')
      end
      check_protection!(take_profit, stop_loss, above: long, field: 'take_profit', reference: 'stop_loss') if stop_loss
      check_protection!(take_profit, break_even(position, fee_bps), above: long, field: 'take_profit', reference: 'break_even', code: 'take_profit_not_profitable')
      check_protection!(stop_loss, Amount.parse(Risk.liquidation(position)), above: long, field: 'stop_loss', reference: 'liquidation', code: 'stop_loss_beyond_liquidation')
    end

    def self.check_protection!(value, boundary, above:, field:, reference:, code: 'invalid_protection')
      return unless value && (above ? value <= boundary : value >= boundary)
      raise Error.new(code, details: {field: field, relation: above ? 'above' : 'below', reference: reference, boundary: Amount.format(boundary)})
    end

    def self.initial_margin(position)
      [position.quantity_units.to_i * position.average_units.to_i / U / position.leverage, 1].max
    end

    def self.order_margin(order)
      reference = Amount.parse(order.details.fetch("reference_price", "0"))
      reference.positive? ? [order.quantity_units.to_i * reference / U / order.leverage, 1].max : order.reserved_units.to_i
    end
  end
end
