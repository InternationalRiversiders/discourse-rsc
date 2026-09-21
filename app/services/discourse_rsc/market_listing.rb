# frozen_string_literal: true
module DiscourseRsc
  class MarketListing
    def self.rows(instruments)
      schedules = MarketSessions.hours
      counts = Order.group(:instrument_id).count
      last = Order.group(:instrument_id).maximum(:created_at)
      legacy = LegacyRecord.where(source_table: "market_instruments").pluck(:data).index_by { |row| row["symbol"] }
      instruments.map do |item|
        metadata = legacy[item.symbol] || {}
        { id: item.id, symbol: item.symbol, display_symbol: metadata["display_symbol"].presence || item.symbol,
          exchange: metadata["exchange"], currency: item.currency, name: item.name, category: item.category, quote: item.quote, market_closed: MarketSessions.closed?(item, schedules: schedules),
          popularity: counts.fetch(item.id, 0), last_order_at: last[item.id], catalog_rank: metadata["catalog_rank"], catalog_id: metadata["id"] || item.id,
          fee_bps: item.fee_bps, close_only: TradingRules.close_only?(item), execution_mode: item.category == "crypto" ? "crypto_confirmation" : (TradingRules.delayed?(item) ? "delayed_confirmation" : "immediate"), history: item.history.last(16), minimum: Amount.format(item.minimum_units), step: Amount.format(item.step_units) }
      end.sort_by do |row|
        [-row[:popularity], -(row[:last_order_at]&.to_f || 0), row[:quote]["price"].nil? ? 1 : 0, row[:catalog_rank] || 2147483647, row[:catalog_id]]
      end
    end
  end
end
