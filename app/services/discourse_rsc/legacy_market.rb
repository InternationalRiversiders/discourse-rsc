# frozen_string_literal: true
module DiscourseRsc
  class LegacyMarket
    def self.restore!
      return { quotes: 0, history_series: 0 } unless LegacyRecord.where(source_table: %w[market_quotes market_candles]).exists?
      raise Error.new("read_only", status: 409) if SiteSetting.rsc_enabled && !Safety.read_only?
      native = Instrument.all.index_by(&:symbol)
      mapping = LegacyRecord.where(source_table: "market_instruments").pluck(:data).to_h { |row| [row["id"].to_s, native[row["symbol"]]] }
      quotes = 0
      LegacyRecord.where(source_table: "market_quotes").find_each do |record|
        row = record.data
        item = mapping[row["instrument_id"].to_s]
        next unless item && item.quote.blank?
        # Missing timestamps must not hide historical display prices. The
        # legacy_snapshot flag always prevents execution with these quotes.
        next unless row["price_rsc"]
        item.update!(quote: { price: row["price_rsc"], previous_close: row["previous_close_rsc"], bid: row["bid_rsc"], ask: row["ask_rsc"],
          source_time: row["source_time"], received_at: row["received_at"], source: row["source"], delay_seconds: row["source_delay_seconds"].to_i,
          session_start: row["regular_session_start"], session_end: row["regular_session_end"], local_price: row["price"], local_currency: row["price_currency"], legacy_snapshot: true })
        quotes += 1
      end
      # Bound memory: query only 50 instruments' candles at a time.
      caches = 0
      mapping.keys.each_slice(50) do |ids|
        groups = LegacyRecord.where(source_table: "market_candles").where("data ->> 'instrument_id' IN (?)", ids).pluck(:data).group_by { |row| [row["instrument_id"].to_s, row["range_key"]] }
        groups.each do |(id, range), rows|
          item = mapping[id]
          next unless item && MarketData::RANGES.key?(range)
          next if HistoryCache.exists?(instrument_id: item.id, range: range)
          rows.sort_by! { |row| row.fetch("candle_time") }
          candles = rows.map { |row| { at: row["candle_time"], open: row["open_rsc"], high: row["high_rsc"], low: row["low_rsc"], close: row["close_rsc"], volume: row["volume"] } }
          HistoryCache.create!(instrument_id: item.id, range: range, candles: candles, currency: "RSC", source: "legacy", updated_at: rows.map { |row| Time.iso8601(row.fetch("updated_at")) }.max)
          item.update!(history: candles.last(16).map { |c| { at: c[:at], price: c[:close] } }) if range == "1d" || item.history.empty?
          caches += 1
        end
      end
      { quotes: quotes, history_series: caches }
    end
  end
end
