# frozen_string_literal: true
module DiscourseRsc
  class MarketData
    RANGES = { "1d" => "5m", "5d" => "30m", "1mo" => "1d", "6mo" => "1d", "1y" => "1wk", "5y" => "1mo" }.freeze
    CATEGORIES = %w[indices forex metals us cn hk jp eu ca au sg in crypto].freeze
    def self.decimal(value)
      number = BigDecimal(value.to_s)
      raise Error.new("provider_invalid_price", status: 503) unless number.finite? && number.positive?
      number.round(18).to_s("F")
    rescue ArgumentError
      raise Error.new("provider_invalid_price", status: 503)
    end

    # Optional display fields must not invalidate an otherwise usable quote.
    def self.optional_price(value, rate = 1)
      decimal(BigDecimal(decimal(value)) * rate) if value.present?
    rescue Error, ArgumentError
      nil
    end

    def self.session_stats(chart, source)
      meta = chart.fetch("meta")
      zone = ActiveSupport::TimeZone[meta["exchangeTimezoneName"].to_s] || ActiveSupport::TimeZone["UTC"]
      day = source.in_time_zone(zone).to_date
      indexes = Array(chart["timestamp"]).each_index.select do |i|
        next false unless chart["timestamp"][i].is_a?(Numeric)
        at = Time.at(chart["timestamp"][i]).utc
        at <= source && at.in_time_zone(zone).to_date == day
      end
      quotes = chart.dig("indicators", "quote", 0) || {}
      { "open" => meta["regularMarketOpen"] || (indexes.first && Array(quotes["open"])[indexes.first]),
        "high" => meta["regularMarketDayHigh"] || indexes.filter_map { |i| optional_price(Array(quotes["high"])[i]) }.max_by { |v| BigDecimal(v) },
        "low" => meta["regularMarketDayLow"] || indexes.filter_map { |i| optional_price(Array(quotes["low"])[i]) }.min_by { |v| BigDecimal(v) } }
    end

    def self.symbol(value)
      value = value.to_s.strip.upcase
      raise Error.new("invalid_symbol") unless /\A[A-Z0-9^][A-Z0-9.^=:\/-]{0,39}\z/.match?(value)
      value
    end

    def self.yahoo_chart(value, range = "1d")
      ProviderHttp.get("query1.finance.yahoo.com", "/v8/finance/chart/#{ERB::Util.url_encode(symbol(value))}", range: range, interval: RANGES.fetch(range), includePrePost: false).dig("chart", "result", 0) || raise(Error.new("provider_no_data", status: 503))
    end

    def self.usd_rate(currency)
      return BigDecimal("1") if currency == "USD"
      # Yahoo prices British shares in pence, rather than pounds.
      base = currency == "GBp" || currency == "GBX" ? "GBP" : currency
      raise Error.new("provider_currency") unless /\A[A-Z]{3}\z/.match?(base)
      value = Discourse.cache.fetch("rsc:fx:#{base}", expires_in: 10.minutes) do
        data = yahoo_chart("#{base}USD=X")
        meta = data.fetch("meta")
        raise Error.new("fx_stale", status: 503) if Time.at(meta.fetch("regularMarketTime")) < 4.days.ago
        decimal(meta.fetch("regularMarketPrice"))
      end
      BigDecimal(value) / (base == currency ? 1 : 100)
    end

    def self.fetch_quote(instrument)
      code = instrument.provider_symbol.presence || instrument.symbol
      case instrument.provider
      when "coinbase"
        raise Error.new("invalid_symbol") unless /\A[A-Z0-9]+-USD\z/.match?(code)
        ticker = ProviderHttp.get("api.exchange.coinbase.com", "/products/#{code}/ticker")
        stats = ProviderHttp.get("api.exchange.coinbase.com", "/products/#{code}/stats")
        { "price" => decimal(ticker.fetch("price")), "previous_close" => decimal(stats.fetch("open")), "change_basis" => "24h",
          "high" => optional_price(stats["high"]), "low" => optional_price(stats["low"]),
          "bid" => decimal(ticker.fetch("bid")), "ask" => decimal(ticker.fetch("ask")),
          "source_time" => Time.iso8601(ticker.fetch("time")).iso8601(6), "delay_seconds" => 0,
          "local_price" => decimal(ticker.fetch("price")), "local_currency" => "USD", "source" => "coinbase" }
      when "kraken"
        raise Error.new("invalid_symbol") unless /\A[A-Z0-9]+USD\z/.match?(code)
        data = ProviderHttp.get("api.kraken.com", "/0/public/Ticker", pair: code)
        raise Error.new("provider_no_data") if data.fetch("error", []).present?
        ticker = data.fetch("result").values.first
        trades = ProviderHttp.get("api.kraken.com", "/0/public/Trades", pair: code, count: 1).fetch("result").reject { |key, _| key == "last" }.values.first
        source_time = Time.at(BigDecimal(trades.last.fetch(2).to_s)).utc
        { "price" => decimal(ticker.fetch("c").first), "previous_close" => decimal(ticker.fetch("o")), "change_basis" => "utc_open",
          "high" => optional_price(ticker.dig("h", 1)), "low" => optional_price(ticker.dig("l", 1)), "bid" => decimal(ticker.fetch("b").first), "ask" => decimal(ticker.fetch("a").first),
          "source_time" => source_time.iso8601(6), "delay_seconds" => 0, "source" => "kraken", "local_currency" => "USD", "local_price" => decimal(ticker.fetch("c").first) }
      when "okx"
        raise Error.new("invalid_symbol") unless /\A[A-Z0-9]+-USDT-SWAP\z/.match?(code)
        data = ProviderHttp.get("www.okx.com", "/api/v5/market/ticker", instId: code)
        raise Error.new("provider_no_data") unless data["code"] == "0"
        ticker = data.fetch("data").first
        # Preserve the old virtual-market USDT accounting convention explicitly.
        { "price" => decimal(ticker.fetch("last")), "previous_close" => decimal(ticker.fetch("open24h")), "change_basis" => "24h",
          "high" => optional_price(ticker["high24h"]), "low" => optional_price(ticker["low24h"]), "bid" => decimal(ticker.fetch("bidPx")), "ask" => decimal(ticker.fetch("askPx")),
          "source_time" => Time.at(BigDecimal(ticker.fetch("ts")) / 1000).utc.iso8601(6), "delay_seconds" => 0, "source" => "okx", "local_currency" => "USDT", "local_price" => decimal(ticker.fetch("last")) }
      when "yahoo", "twelve_data"
        # Yahoo supplies the authoritative exchange session boundaries for both adapters.
        chart = yahoo_chart(code)
        meta = chart.fetch("meta")
        session = meta.dig("currentTradingPeriod", "regular") || {}
        currency = meta.fetch("currency", instrument.currency)
        raw = meta.fetch("regularMarketPrice")
        previous = meta["chartPreviousClose"] || meta["previousClose"]
        source = Time.at(meta.fetch("regularMarketTime")).utc
        delay = Integer(meta.fetch("exchangeDataDelayedBy", 0)) * 60
        stats = session_stats(chart, source)
        if instrument.provider == "twelve_data"
          key = SiteSetting.rsc_twelve_data_api_key
          raise Error.new("provider_key_required", status: 503) if key.blank?
          td = ProviderHttp.get("api.twelvedata.com", "/quote", symbol: code, apikey: key)
          raise Error.new("provider_no_data", status: 503) unless td["close"] && td["timestamp"]
          raw, previous, currency = td["close"], td["previous_close"], td.fetch("currency", currency)
          source = Time.at(Integer(td["timestamp"])).utc
          stats = td.slice("open", "high", "low")
          # Never silently reinterpret delayed account data as real-time.
          delay = [delay, SiteSetting.rsc_twelve_data_delay_seconds].max
        end
        rate = usd_rate(currency)
        { "price" => decimal(BigDecimal(decimal(raw)) * rate),
          "previous_close" => previous && decimal(BigDecimal(decimal(previous)) * rate),
          "local_price" => decimal(raw), "local_currency" => currency, "fx_rate" => rate.to_s("F"),
          "open" => optional_price(stats["open"], rate), "high" => optional_price(stats["high"], rate), "low" => optional_price(stats["low"], rate), "change_basis" => "previous_close",
          "source_time" => source.iso8601, "delay_seconds" => delay,
          "delay_reported" => instrument.provider != 'yahoo' || !meta['exchangeDataDelayedBy'].nil?,
          "session_start" => session["start"] && Time.at(session["start"]).utc.iso8601,
          "session_end" => session["end"] && Time.at(session["end"]).utc.iso8601, "source" => instrument.provider }
      else
        raise Error.new("provider_not_configured", status: 503)
      end.merge("received_at" => Time.current.iso8601(6))
    end

    def self.sync_one(instrument)
      quote = fetch_quote(instrument)
      record_quote(instrument, quote)
      true
    rescue Error, KeyError, ArgumentError => error
      instrument.update!(provider_error: error.is_a?(Error) ? error.code : "provider_invalid_data", synced_at: Time.current)
      false
    end

    def self.record_quote(instrument, quote, stream: false)
      instrument.with_lock do
        old_time = Time.iso8601(instrument.quote["source_time"]) rescue Time.at(0)
        if Time.iso8601(quote.fetch("source_time")) >= old_time
          quote = observe_delay(instrument.quote, quote, category: instrument.category)
          attributes = {quote: quote, provider_error: nil, synced_at: Time.current}
          last_point = Time.iso8601(instrument.history.last&.fetch('at', nil)) rescue Time.at(0)
          if !stream || Time.iso8601(quote['source_time']) >= last_point + 60
            history = instrument.history.reject { |point| point['at'] == quote['source_time'] }
            history << {'at' => quote['source_time'], 'price' => quote['price']}
            attributes[:history] = history.last(1440)
          end
          instrument.update!(attributes)
        end
      end
      true
    end

    def self.sync_crypto(ids)
      return [] if Safety.read_only? || !SiteSetting.rsc_market_data_enabled
      items = Instrument.where(id: ids, active: true, category: 'crypto').order(Arel.sql('synced_at ASC NULLS FIRST')).to_a
      queue = Queue.new
      items.each { |item| queue << item.id }
      done = Queue.new
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      Array.new([3, items.size].min) do
        Thread.new do
          Rails.application.executor.wrap do
            while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
              id = queue.pop(true) rescue nil
              break unless id
              ActiveRecord::Base.connection_pool.with_connection do
                refresh_if_needed(id, purpose: :fast)
                done << id
              end
            end
          end
        end
      end.each(&:value)
      done.size.times.map { done.pop }
    end

    def self.refresh_if_needed(instrument_id, purpose: :read)
      instrument = Instrument.find(instrument_id)
      return instrument if Safety.read_only? || !SiteSetting.rsc_market_data_enabled ||
        !instrument.active || !%w[yahoo coinbase twelve_data kraken okx].include?(instrument.provider)
      # The same lock/cache covers page reads, orders and scheduled refreshes.
      # No money transaction or instrument row lock is held during HTTP.
      DistributedMutex.synchronize("rsc-quote:#{instrument.id}", validity: 90) do
        instrument.reload
        sync_one(instrument) if refresh_due?(instrument, purpose: purpose)
      end
      instrument.reload
    end

    def self.refresh_due?(instrument, purpose: :read, schedules: nil)
      return false if MarketSessions.closed?(instrument, schedules: schedules) && instrument.quote['price'].present?
      q = instrument.quote
      received = Time.iso8601(q['received_at']) rescue nil
      # Failures do not manufacture a fresh quote. Provider-wide cooldown is an
      # additional guard and is shared even when different symbols are requested.
      retry_age = instrument.provider_error == 'provider_busy' ? 15 : 120
      return false if instrument.provider_error.present? && instrument.synced_at && instrument.synced_at > retry_age.seconds.ago
      age = case purpose
      when :trade then q['source'] == 'coinbase_ws' ? 3 : 20
      when :fast then 15
      when :background then 15 # The poll runs once/minute; allow its previous batch to finish late.
      when :idle then 15 * 60
      else TradingRules.delayed?(instrument) ? 90 : 120
      end
      !(received && received > age.seconds.ago && received <= 5.seconds.from_now && !q['legacy_snapshot'])
    end

    def self.observe_delay(previous, quote, category:)
      return quote unless quote['source']=='yahoo' && !quote['delay_reported'] && category!='crypto'
      source=Time.iso8601(quote.fetch('source_time'));received=Time.iso8601(quote.fetch('received_at'))
      starts=quote['session_start'] && Time.iso8601(quote['session_start'])
      ends=quote['session_end'] && Time.iso8601(quote['session_end'])
      # Never turn a closed session, yesterday's price, or a frozen feed into a
      # delayed live quote. Learn only from recent, advancing source timestamps.
      return quote unless starts && ends && received>=starts && received<ends && source>=starts
      samples=Array(previous['delay_observations']).select do |sample|
        Time.iso8601(sample.fetch('received_at'))>=received-10.minutes && Time.iso8601(sample.fetch('source_time'))>=starts
      end
      if previous['source_time']==quote['source_time']
        if previous['delay_inferred']
          quote['delay_seconds']=previous['delay_seconds'];quote['delay_inferred']=true
        end
      else
        lag=(received-source).ceil
        if lag.between?(180,3600)
          samples << {'source_time'=>quote['source_time'],'received_at'=>quote['received_at'],'lag'=>lag}
          samples=samples.last(3)
          lags=samples.map { |sample| sample.fetch('lag') }
          if lags.size>=2 && lags.max-lags.min<=90 && Time.iso8601(samples.last['source_time'])>Time.iso8601(samples.first['source_time'])
            quote['delay_seconds']=lags.max;quote['delay_inferred']=true
          end
        else
          samples=[]
        end
      end
      quote.merge('delay_observations'=>samples)
    end

    def self.sync
      return {} if Safety.read_only? || !SiteSetting.rsc_market_data_enabled
      # Fetch instruments with open exposure first. Idle catalog instruments use
      # the remaining provider budget and rotate by last attempt, including errors.
      active_ids = Position.distinct.pluck(:instrument_id) | Order.where(status: "pending").distinct.pluck(:instrument_id)
      scope = Instrument.where(active: true, provider: %w[yahoo coinbase twelve_data kraken okx])
      schedules = MarketSessions.hours
      priority = scope.where(id: active_ids).order(Arel.sql("synced_at ASC NULLS FIRST")).select { |item| refresh_due?(item, purpose: :background, schedules: schedules) }.first(SiteSetting.rsc_market_sync_batch)
      remaining = SiteSetting.rsc_market_sync_batch - priority.size
      # At most five unheld catalog symbols per minute; cold browsing remains
      # on demand. Never scan the entire cold catalog in every cycle.
      idle = scope.where.not(id: active_ids).order(Arel.sql("synced_at ASC NULLS FIRST")).select { |item| refresh_due?(item, purpose: :idle, schedules: schedules) }.first([remaining, 5].min)
      items = priority + idle
      # Bound a cycle to 45 seconds plus in-flight HTTP timeouts. Three workers
      # leave room in the shared three-second provider queue for page requests.
      # Failed quotes never become fresh.
      queue = Queue.new
      items.each { |item| queue << item.id }
      results = {}
      result_lock = Mutex.new
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
      Array.new([3, items.size].min) do
        Thread.new do
          Rails.application.executor.wrap do
            while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
              id = queue.pop(true) rescue nil
              break unless id
              ActiveRecord::Base.connection_pool.with_connection do
                item = Instrument.find(id)
                refreshed = refresh_if_needed(item.id, purpose: active_ids.include?(id) ? :background : :idle)
                ok = refreshed.provider_error.blank?
                result_lock.synchronize { results[item.symbol] = ok }
              end
            end
          end
        end
      end.each(&:value)
      results
    end

    def self.health
      ids = Position.distinct.pluck(:instrument_id) | Order.where(status: "pending").distinct.pluck(:instrument_id)
      items = Instrument.where(id: ids).to_a
      stale = items.filter_map do |item|
        Exchange.price!(item)
        nil
      rescue Error
        { id: item.id, symbol: item.symbol, error: item.provider_error, synced_at: item.synced_at }
      end
      schedules = MarketSessions.hours
      open_items = items.reject { |item| MarketSessions.closed?(item, schedules: schedules) }
      # A row count alone is not a capacity test: Yahoo needs one second per
      # request before network time/FX lookups, within a 45-second worker budget.
      lower_bound = open_items.count { |item| %w[yahoo twelve_data].include?(item.provider) }
      { exposed: items.size, open_exposed: open_items.size, minimum_provider_seconds: lower_bound,
        batch: SiteSetting.rsc_market_sync_batch, capacity_ok: open_items.size <= SiteSetting.rsc_market_sync_batch && lower_bound <= 40,
        stale: stale, fresh: items.size - stale.size }
    end

    def self.search(query)
      raise Error.new("invalid_search") unless query.is_a?(String) && query.strip.length.between?(2, 60)
      Discourse.cache.fetch("rsc:search:#{Digest::SHA256.hexdigest(query)}", expires_in: 5.minutes) do
        result = ProviderHttp.get("query1.finance.yahoo.com", "/v1/finance/search", q: query, quotesCount: 12, newsCount: 0)
        Array(result["quotes"]).filter_map do |item|
          next unless item["symbol"] && item["isYahooFinance"] != false && Catalog.supported_external?(item["symbol"], item["quoteType"])
          { symbol: item["symbol"], name: item["shortname"] || item["longname"] || item["symbol"], exchange: item["exchange"], type: item["quoteType"] }
        end
      end
    end

    def self.history(instrument, range)
      raise Error.new("invalid_range") unless RANGES.key?(range)
      DistributedMutex.synchronize("rsc-chart:#{instrument.id}:#{range}", validity: 180) do
        history_uncached(instrument, range)
      end
    end

    def self.history_uncached(instrument, range)
      raise Error.new("invalid_range") unless RANGES.key?(range)
      cache = HistoryCache.find_by(instrument_id: instrument.id, range: range)
      if cache && (cache.updated_at > (range == "1d" ? 2.minutes.ago : 10.minutes.ago) || MarketSessions.closed?(instrument) || (!SiteSetting.rsc_market_data_enabled && cache.source == "legacy"))
        return { candles: cache.candles, currency: cache.currency || instrument.currency, updated_at: cache.updated_at, archived: cache.source == "legacy" }
      end
      if instrument.provider == "manual"
        return { candles: instrument.history.last(1440).map { |p| { at: p["at"], close: p["price"] } }, currency: "RSC", updated_at: instrument.updated_at }
      end
      raise Error.new("provider_disabled", status: 503) unless SiteSetting.rsc_market_data_enabled
      if instrument.provider == "coinbase"
        chart_currency = "USD"
        granularity, days = { "1d" => [300, 1], "5d" => [3600, 5], "1mo" => [21600, 30], "6mo" => [86400, 180], "1y" => [86400, 365], "5y" => [86400, 1826] }.fetch(range)
        finish = Time.current.to_i
        start = finish - days * 86400
        candles = []
        while start < finish
          through = [start + granularity * 299, finish].min
          rows = ProviderHttp.get("api.exchange.coinbase.com", "/products/#{symbol(instrument.provider_symbol || instrument.symbol)}/candles", granularity: granularity, start: Time.at(start).utc.iso8601, end: Time.at(through).utc.iso8601)
          raise Error.new("provider_invalid_data") unless rows.is_a?(Array)
          candles.concat(rows.map { |at, low, high, open, close, volume| { at: Time.at(at).utc.iso8601, open: decimal(open), high: decimal(high), low: decimal(low), close: decimal(close), volume: volume.to_s } })
          start = through
        end
        candles = candles.uniq { |c| c[:at] }.sort_by { |c| c[:at] }
      elsif instrument.provider == "kraken"
        chart_currency = "USD"
        interval = { "1d" => 5, "5d" => 15, "1mo" => 60, "6mo" => 1440, "1y" => 1440, "5y" => 10080 }.fetch(range)
        data = ProviderHttp.get("api.kraken.com", "/0/public/OHLC", pair: symbol(instrument.provider_symbol), interval: interval)
        rows = data.fetch("result").reject { |key, _| key == "last" }.values.first
        candles = rows.map { |at, open, high, low, close, vwap, volume, count| { at: Time.at(at).utc.iso8601, open: decimal(open), high: decimal(high), low: decimal(low), close: decimal(close), volume: volume.to_s } }
      elsif instrument.provider == "okx"
        chart_currency = "USDT"
        bar = { "1d" => "5m", "5d" => "30m", "1mo" => "4H", "6mo" => "1D", "1y" => "1W", "5y" => "1M" }.fetch(range)
        data = ProviderHttp.get("www.okx.com", "/api/v5/market/history-candles", instId: symbol(instrument.provider_symbol), bar: bar, limit: 300)
        raise Error.new("provider_no_data") unless data["code"] == "0"
        candles = data.fetch("data").map { |at, open, high, low, close, volume, *rest| { at: Time.at(BigDecimal(at) / 1000).utc.iso8601, open: decimal(open), high: decimal(high), low: decimal(low), close: decimal(close), volume: volume.to_s } }.reverse
      else
        chart = yahoo_chart(instrument.provider_symbol || instrument.symbol, range)
        chart_currency = chart.dig("meta", "currency").presence || instrument.currency
        quote = chart.dig("indicators", "quote", 0) || {}
        candles = Array(chart["timestamp"]).each_with_index.filter_map do |at, index|
          next unless %w[open high low close].all? { |key| quote.dig(key, index) }
          { at: Time.at(at).utc.iso8601, open: decimal(quote["open"][index]), high: decimal(quote["high"][index]), low: decimal(quote["low"][index]), close: decimal(quote["close"][index]), volume: quote.dig("volume", index)&.to_s }
        end
      end
      cache ||= HistoryCache.new(instrument_id: instrument.id, range: range)
      cache.update!(candles: candles, currency: chart_currency, source: "provider", updated_at: Time.current)
      { candles: candles, currency: chart_currency, updated_at: cache.updated_at }
    rescue Error => error
      raise unless cache && cache.candles.present?
      { candles: cache.candles, currency: cache.currency || instrument.currency, updated_at: cache.updated_at,
        archived: cache.source == "legacy", stale: true, refresh_error: error.code }
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
