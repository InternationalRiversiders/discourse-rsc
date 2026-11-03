# frozen_string_literal: true
module DiscourseRsc
  # Shared FX/US backup budget. No API keys, URLs or user identities in metrics.
  module FallbackBudget
    RETENTION = 14.days.to_i
    COLD_LIMIT = 60
    RESERVE = <<~LUA
      if tonumber(redis.call('GET', KEYS[2]) or '0') >= 750 then return -2 end
      if ARGV[1] == '1' and tonumber(redis.call('GET', KEYS[3]) or '0') >= 60 then return -3 end
      if not redis.call('SET', KEYS[1], '1', 'NX', 'EX', 8) then return -1 end
      local used = redis.call('INCR', KEYS[2])
      redis.call('EXPIRE', KEYS[2], ARGV[2])
      if ARGV[1] == '1' then
        redis.call('INCR', KEYS[3]); redis.call('EXPIRE', KEYS[3], ARGV[2])
      end
      return used
    LUA
    REFUND = <<~LUA
      for _, key in ipairs(KEYS) do
        if tonumber(redis.call('GET', key) or '0') > 0 then redis.call('DECR', key) end
      end
      return 1
    LUA

    def self.with_context(purpose)
      previous = Thread.current[:rsc_fallback_purpose]
      Thread.current[:rsc_fallback_purpose] = purpose
      yield
    ensure
      Thread.current[:rsc_fallback_purpose] = previous
    end

    def self.exposed?(id)
      Position.where(instrument_id: id).exists? || Order.where(instrument_id: id, status: 'pending').exists?
    end

    def self.operation(instrument)
      case Thread.current[:rsc_fallback_purpose]
      when :trade then 'open_order'
      when :exit then 'close_order'
      when :execution then 'pending_order'
      when :read then 'detail_view'
      when :forex_review then ForexReviewQueue.requested?(instrument.id) ? 'requested_review' : exposed?(instrument.id) ? 'held_review' : 'watched_review'
      when :forex_fast, :background, :idle then exposed?(instrument.id) ? 'holding_refresh' : 'idle_refresh'
      else 'direct_execution'
      end
    end

    def self.metric(day, symbol, operation, reason, outcome)
      key = "rsc:fallback-usage:#{day}"
      Discourse.redis.hincrby(key, [symbol, operation, reason, outcome].join('|'), 1)
      Discourse.redis.expire(key, RETENTION)
      Discourse.redis.set("#{key}:started_at", Time.current.iso8601(6), nx: true, ex: RETENTION)
    end

    def self.request(instrument, reason:)
      day = Time.current.utc.to_date
      op = operation(instrument)
      cold = !%w[open_order close_order pending_order requested_review direct_execution].include?(op) && !exposed?(instrument.id)
      total_key = "rsc:fx-fallback:requests:#{day}"
      cold_key = "rsc:fx-fallback:cold:#{day}"
      used = ProviderHttp.evaluate(RESERVE, keys: ['rsc:fx-fallback:slot', total_key, cold_key], argv: [cold ? '1' : '0', RETENTION])
      if used.negative?
        code = {-1 => 'provider_busy', -2 => 'provider_daily_limit', -3 => 'provider_background_budget'}.fetch(used)
        metric(day, instrument.symbol, op, reason, "blocked:#{code}")
        raise Error.new(code, status: 503)
      end
      begin
        value = yield
      rescue StandardError => error
        code = error.is_a?(Error) ? error.code : 'provider_invalid_data'
        if %w[provider_busy provider_cooldown].include?(code)
          # These errors are raised by ProviderHttp.pace! BEFORE any HTTP I/O.
          # Keep the eight-second pacing slot, but return the unspent credit.
          ProviderHttp.evaluate(REFUND, keys: cold ? [total_key, cold_key] : [total_key], argv: [])
          metric(day, instrument.symbol, op, reason, "not_sent:#{code}")
        else
          metric(day, instrument.symbol, op, reason, 'requests')
          metric(day, instrument.symbol, op, reason, "failed:#{code}")
        end
        raise
      else
        metric(day, instrument.symbol, op, reason, 'requests')
        metric(day, instrument.symbol, op, reason, 'success')
        value
      end
    end

    def self.report(day = Time.current.utc.to_date)
      key = "rsc:fallback-usage:#{day}"
      { day: day, timezone: 'UTC', total_reserved: Discourse.redis.get("rsc:fx-fallback:requests:#{day}").to_i,
        cold_used: Discourse.redis.get("rsc:fx-fallback:cold:#{day}").to_i, cold_limit: COLD_LIMIT,
        tracked_since: Discourse.redis.get("#{key}:started_at"),
        rows: Discourse.redis.hgetall(key).map { |field, count| symbol, op, reason, outcome = field.split('|'); {symbol: symbol, operation: op, reason: reason, outcome: outcome, count: count.to_i} } }
    end
  end
end
