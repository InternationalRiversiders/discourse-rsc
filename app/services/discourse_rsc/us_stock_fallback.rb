# frozen_string_literal: true
module DiscourseRsc
  # On-demand US quote backup; shares the FX credit ceiling and pacing slot.
  # Separate opt-in because external US-equity display needs provider permission.
  module UsStockFallback
    def self.quote(instrument, primary)
      return primary unless SiteSetting.rsc_us_stock_fallback_enabled &&
        SiteSetting.rsc_twelve_data_api_key.present? && instrument.category == 'us' && instrument.provider == 'yahoo'
      return primary if ForexQuoteGuard.fresh?(primary) && !primary['legacy_snapshot']
      return primary if MarketSessions.closed?(instrument)
      code = (instrument.provider_symbol.presence || instrument.symbol.split(':').last).tr('-', '.')
      return primary unless /\A[A-Z][A-Z0-9.]{0,14}\z/.match?(code)
      cache_key = "rsc:us-fallback:v1:#{code}"
      retry_key = "rsc:us-fallback:retry:#{code}"
      requested = false
      result = Discourse.cache.fetch(cache_key, expires_in: 60.seconds) do
        raise Error.new('provider_cooldown') if Discourse.redis.exists?(retry_key)
        used = ProviderHttp.evaluate(MarketData::FALLBACK_RESERVE,
          keys: ['rsc:fx-fallback:slot', "rsc:fx-fallback:requests:#{Time.current.utc.to_date}"], argv: [])
        raise Error.new(used == -2 ? 'provider_daily_limit' : 'provider_busy') if used.negative?
        requested = true
        data = ProviderHttp.get('api.twelvedata.com', '/quote', symbol: code, interval: '1min',
          timezone: 'UTC', dp: 11, apikey: SiteSetting.rsc_twelve_data_api_key)
        raise Error.new('provider_invalid_data') unless data['symbol'] == code && data['currency'] == 'USD' && data['is_market_open'] == true
        source = Time.at(Integer(data.fetch('timestamp'))).utc
        raise Error.new('quote_stale') unless source.between?(180.seconds.ago, 5.seconds.from_now)
        day = source.in_time_zone('America/New_York').beginning_of_day
        start = day.change(hour: 9, min: 30)
        finish = day.change(hour: 16)
        raise Error.new('market_closed') unless source.between?(start, finish) && Time.current.between?(start, finish)
        price = MarketData.decimal(data.fetch('close'))
        # /quote's timestamp is the interval start, not a per-trade timestamp.
        # Explicit 1min prevents treating a daily candle's opening time as live.
        { 'price' => price, 'local_price' => price, 'local_currency' => 'USD', 'fx_rate' => '1',
          'source' => 'twelve_data', 'source_time' => source.iso8601, 'received_at' => Time.current.iso8601(6),
          'delay_seconds' => 0, 'delay_reported' => true, 'fallback' => true,
          'session_start' => start.iso8601, 'session_end' => finish.iso8601,
          'previous_close' => MarketData.optional_price(data['previous_close']), 'change_basis' => 'previous_close' }
      end
      unless ForexQuoteGuard.fresh?(result)
        Discourse.cache.delete(cache_key)
        return primary
      end
      result
    rescue Error, KeyError, ArgumentError, TypeError
      Discourse.redis.setex(retry_key, 90, 'unavailable') if requested
      primary
    end
  end
end
