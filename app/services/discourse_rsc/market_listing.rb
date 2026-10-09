# frozen_string_literal: true
module DiscourseRsc
  class MarketListing
    # Share the exchange's deterministic bid/ask (or tick-spread) calculation.
    # Delayed trades reserve against the reference price with their own buffer.
    def self.execution_prices(item)
      return if item.category == "crypto" || TradingRules.delayed?(item)
      price = Amount.positive(item.quote["price"])
      %w[long short].to_h { |side| [side, Amount.format(Exchange.execution_price(item, side, price))] }
    rescue Error
      nil
    end

    # Shared display-only snapshot; execution always reloads authoritative quotes.
    def self.catalog
      Rails.cache.fetch('rsc:market:catalog:v1', expires_in: 10.seconds) do
        columns = Instrument.column_names.reject { |column| column == 'history' }
        items = Instrument.where(active: true).select(*columns)
          .select(Arel.sql("jsonb_path_query_array(history, '$[last - 59 to last]') AS history")).order(:symbol).to_a
        rows(items, execution: false)
      end
    end

    def self.tradable?(row, now = Time.current)
      q = row[:quote]
      return false if q['legacy_snapshot'] || q['price'].to_f <= 0 || row[:market_closed]
      received = Time.iso8601(q.fetch('received_at')); source = Time.iso8601(q.fetch('source_time'))
      delay = [q['delay_seconds'].to_i, 0].max
      fresh = received >= now - 120 && received <= now + 5 && source <= now + 5 && source >= now - delay - 120
      fresh && (row[:category] == 'crypto' || (now >= Time.iso8601(q.fetch('session_start')) && now < Time.iso8601(q.fetch('session_end'))))
    rescue ArgumentError, KeyError, TypeError
      false
    end

    def self.page(params)
      all = catalog
      categories = all.map { |row| row[:category] }.uniq
      category = params[:market_category].presence || (all.any? { |row| tradable?(row) } ? 'tradable' : 'all')
      category = 'all' unless (categories + %w[all tradable]).include?(category)
      query = params[:market_search].to_s.strip.first(100).downcase
      sort = %w[popular symbol gainers losers].include?(params[:market_sort]) ? params[:market_sort] : 'popular'
      found = all.select do |row|
        (category == 'all' || (category == 'tradable' ? tradable?(row) : row[:category] == category)) &&
          %i[symbol display_symbol exchange currency name category].map { |field| row[field] }.join(' ').downcase.include?(query)
      end
      if sort == 'symbol'
        found = found.sort_by { |row| row[:symbol] }
      elsif %w[gainers losers].include?(sort)
        found = found.sort_by do |row|
          q = row[:quote]; previous = q['previous_close'].to_f; price = q['price'].to_f
          change = previous.positive? && price.positive? ? (price / previous - 1) : nil
          [change ? 0 : 1, change ? change * (sort == 'gainers' ? -1 : 1) : 0, row[:symbol]]
        end
      end
      pages = [(found.size / 20.0).ceil, 1].max
      page = [[params[:market_page].to_i, 1].max, pages].min
      page_ids = found.slice((page - 1) * 20, 20).map { |row| row[:id] }
      current = rows(Instrument.where(id: page_ids).to_a).index_by { |row| row[:id] }
      { rows: page_ids.filter_map { |id| current[id] }, categories: categories, category: category, search: query, sort: sort,
        pagination: { total: found.size, page: page, pages: pages, scope: "#{query}/#{category}/#{sort}" } }
    end

    def self.rows(instruments, execution: true)
      upcoming = Dividend.includes(:instrument).where(instrument_id: instruments.map(&:id), status: "approved").order(:effective_at).group_by(&:instrument_id)
      schedules = MarketSessions.hours
      counts = Order.group(:instrument_id).count
      last = Order.group(:instrument_id).maximum(:created_at)
      legacy = Rails.cache.fetch('rsc:market:metadata:v1', expires_in: 10.minutes) do
        fields = %w[symbol display_symbol exchange catalog_rank id]
        LegacyRecord.where(source_table: "market_instruments")
          .pluck(*fields.map { |field| Arel.sql("data->>'#{field}'") })
          .to_h { |values| row = fields.zip(values).to_h; [row['symbol'], row] }
      end
      instruments.map do |item|
        metadata = legacy[item.symbol] || {}
        { id: item.id, symbol: item.symbol, display_symbol: metadata["display_symbol"].presence || item.symbol,
          exchange: metadata["exchange"], currency: item.currency, name: item.name, category: item.category, quote: item.quote, market_closed: MarketSessions.closed?(item, schedules: schedules),
          minimum_notional: TradingRules.stock?(item) ? "1" : nil,
          execution_prices: execution ? execution_prices(item) : nil,
          popularity: counts.fetch(item.id, 0), last_order_at: last[item.id], catalog_rank: metadata["catalog_rank"]&.to_i, catalog_id: metadata["id"]&.to_i || item.id,
          dividend: upcoming[item.id]&.first && Dividends.view(upcoming[item.id].first), fee_bps: item.fee_bps, close_only: TradingRules.close_only?(item), execution_mode: item.category == "crypto" ? "crypto_confirmation" : (TradingRules.delayed?(item) ? "delayed_confirmation" : "immediate"), history: item.history.last(16), minimum: Amount.format(item.minimum_units), step: Amount.format(item.step_units) }
      end.sort_by do |row|
        [-row[:popularity], -(row[:last_order_at]&.to_f || 0), row[:quote]["price"].nil? ? 1 : 0, row[:catalog_rank] || 2147483647, row[:catalog_id]]
      end
    end
  end
end
