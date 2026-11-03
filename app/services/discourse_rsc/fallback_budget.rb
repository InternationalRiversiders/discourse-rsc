# frozen_string_literal: true
module DiscourseRsc
  # Shared FX/US backup budget. No API keys, URLs or user identities in metrics.
  module FallbackBudget
    RETENTION = 14.days.to_i
    DAILY_LIMIT = 750
    RESERVE = <<~LUA
      if tonumber(redis.call('GET', KEYS[2]) or '0') >= 750 then return -2 end
      if not redis.call('SET', KEYS[1], '1', 'NX', 'EX', 8) then return -1 end
      local used = redis.call('INCR', KEYS[2])
      redis.call('EXPIRE', KEYS[2], ARGV[1])
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

    def self.executable_order?(instrument)
      Order.where(instrument_id: instrument.id, status: 'pending')
        .where('execute_at <= ? AND expires_at > ?', Time.current, Time.current).exists?
    end

    # Fail closed: holdings, page views and a recent failed submission are not
    # orders. Background review may spend credits only for a live due order.
    def self.allowed?(instrument)
      case Thread.current[:rsc_fallback_purpose]
      when :trade, :exit then true
      when :execution, :forex_review then executable_order?(instrument)
      else false
      end
    end

    def self.operation(instrument)
      case Thread.current[:rsc_fallback_purpose]
      when :trade then 'open_order'
      when :exit then 'close_order'
      when :execution then 'pending_order'
      when :forex_review then 'pending_order_review'
      else 'non_trading'
      end
    end

    def self.metric(day, symbol, operation, reason, outcome)
      key = "rsc:fallback-usage:#{day}"
      Discourse.redis.hincrby(key, [symbol, operation, reason, outcome].join('|'), 1)
      Discourse.redis.expire(key, RETENTION)
      Discourse.redis.set("#{key}:started_at", Time.current.iso8601(6), nx: true, ex: RETENTION)
    end

    def self.request(instrument, reason:)
      raise Error.new('provider_execution_only', status: 409) unless allowed?(instrument)
      day = Time.current.utc.to_date
      op = operation(instrument)
      total_key = "rsc:fx-fallback:requests:#{day}"
      used = ProviderHttp.evaluate(RESERVE, keys: ['rsc:fx-fallback:slot', total_key], argv: [RETENTION])
      if used.negative?
        code = used == -1 ? 'provider_busy' : 'provider_daily_limit'
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
          ProviderHttp.evaluate(REFUND, keys: [total_key], argv: [])
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
        policy: 'execution_only', daily_limit: DAILY_LIMIT,
        tracked_since: Discourse.redis.get("#{key}:started_at"),
        rows: Discourse.redis.hgetall(key).map { |field, count| symbol, op, reason, outcome = field.split('|'); {symbol: symbol, operation: op, reason: reason, outcome: outcome, count: count.to_i} } }
    end
  end
end
