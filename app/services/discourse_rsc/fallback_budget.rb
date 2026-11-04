# frozen_string_literal: true
module DiscourseRsc
  # Shared FX/US backup budget. No API keys, URLs or user identities in metrics.
  module FallbackBudget
    RETENTION = 14.days.to_i
    DAILY_LIMIT = 750
    ROUTINE_LIMIT = 150
    NON_PRIORITY_CEILING = 450 # Routine checks stop early.
    OPENING_CEILING = 650 # Preserve the last 100 for exits/imminent triggers.
    PROTECTION_CEILING = 600 # Leave 50 additional credits for user submissions.
    ROUTINE_INTERVAL = 600
    ROUTINE_GLOBAL_INTERVAL = 576 # Spread 150 normal probes across a full day.
    RESERVE = <<~LUA
      local used = tonumber(redis.call('GET', KEYS[2]) or '0')
      local tier, now = ARGV[2], tonumber(ARGV[3])
      if used >= 750 then return {-2} end
      if tier == 'routine' and used >= 450 then return {-3} end
      if tier == 'opening' and used >= 650 then return {-3} end
      local old_symbol = redis.call('GET', KEYS[4]) or ''
      local old_routine = redis.call('GET', KEYS[5]) or ''
      local old_protection = redis.call('GET', KEYS[6]) or ''
      local new_symbol = old_symbol
      local started, count = string.match(old_symbol, '^([%d%.]+):(%d+)$')
      started, count = tonumber(started) or 0, tonumber(count) or 0
      local burst = ARGV[4] == 'quote_verification' and started > 0 and now - started <= 240 and count < 3
      if tier == 'routine' or tier == 'protection' then
        new_symbol = burst and (tostring(started)..':'..tostring(count+1)) or (tostring(now)..':1')
      end
      if tier == 'routine' then
        if tonumber(redis.call('GET', KEYS[3]) or '0') >= 150 then return {-3} end
        if not burst and (now - started < 600 or now - (tonumber(old_routine) or 0) < 576) then return {-4} end
      elseif tier == 'protection' then
        -- Pace non-imminent protection checks using time and quota remaining.
        -- Keep 50 for openings and 100 for imminent triggers/exits; urgency bypasses pacing.
        local remaining = 600 - used
        if remaining <= 0 then return {-3} end
        local interval = math.max(60, math.ceil(tonumber(ARGV[5]) / remaining))
        if not burst and now - (tonumber(old_protection) or 0) < interval then return {-4} end
      end
      if not redis.call('SET', KEYS[1], '1', 'NX', 'EX', 8) then return {-1} end
      used = redis.call('INCR', KEYS[2])
      redis.call('EXPIRE', KEYS[2], ARGV[1])
      if tier == 'routine' or tier == 'protection' then redis.call('SET', KEYS[4], new_symbol, 'EX', 600) end
      if tier == 'routine' then
        redis.call('INCR', KEYS[3]); redis.call('EXPIRE', KEYS[3], ARGV[1])
        if not burst then
          redis.call('SET', KEYS[5], ARGV[3], 'EX', 600)
        end
      elseif tier == 'protection' and not burst then
        redis.call('SET', KEYS[6], ARGV[3], 'EX', 86400)
      end
      return {used, old_symbol, old_routine, old_protection, new_symbol}
    LUA
    REFUND = <<~LUA
      for i=1,2 do
        if (i == 1 or ARGV[7] == 'routine') and tonumber(redis.call('GET', KEYS[i]) or '0') > 0 then redis.call('DECR', KEYS[i]) end
      end
      -- Restore only this reservation's pacing state, never a newer request's.
      for i=3,5 do
        local applies = (i == 3 and (ARGV[7] == 'routine' or ARGV[7] == 'protection')) or (i == 4 and ARGV[7] == 'routine') or (i == 5 and ARGV[7] == 'protection')
        if applies and redis.call('GET', KEYS[i]) == ARGV[i-2] then
          local old = ARGV[i+1]
          if old == '' then redis.call('DEL', KEYS[i]) else redis.call('SET', KEYS[i], old, 'EX', 86400) end
        end
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

    def self.allowed?(instrument)
      ExecutionDemand.allowed?(instrument.id, purpose: Thread.current[:rsc_fallback_purpose])
    end

    def self.operation(instrument)
      ExecutionDemand.operation(instrument.id, purpose: Thread.current[:rsc_fallback_purpose])
    end

    def self.metric(day, symbol, operation, reason, outcome)
      key = "rsc:fallback-usage:#{day}"
      Discourse.redis.hincrby(key, [symbol, operation, reason, outcome].join('|'), 1)
      Discourse.redis.expire(key, RETENTION)
      Discourse.redis.set("#{key}:started_at", Time.current.iso8601(6), nx: true, ex: RETENTION)
    end

    def self.review_can_resume?(instrument)
      tier = ExecutionDemand.priority(instrument, purpose: Thread.current[:rsc_fallback_purpose])
      return true if %i[exit urgent].include?(tier)
      used = Discourse.redis.get("rsc:fx-fallback:requests:#{Time.current.utc.to_date}").to_i
      return used < OPENING_CEILING if tier == :opening
      return false unless tier == :protection && used < PROTECTION_CEILING
      now = Time.current
      interval = [60, ((now.utc.tomorrow.beginning_of_day - now) / (PROTECTION_CEILING-used)).ceil].max
      now.to_f - Discourse.redis.get('rsc:fallback-protection-slot').to_f >= interval
    end

    def self.record_request(day, instrument, operation, reason, tier)
      metric(day, instrument.symbol, operation, reason, 'requests')
      ForexReviewQueue.record_opening_request(instrument.id) if tier == :opening
      key = "rsc:fallback-priority:#{day}"
      Discourse.redis.hincrby(key, tier.to_s, 1)
      Discourse.redis.expire(key, RETENTION)
    end

    def self.request(instrument, reason:)
      raise Error.new('provider_execution_only', status: 409) unless allowed?(instrument)
      day = Time.current.utc.to_date
      op = operation(instrument)
      total_key = "rsc:fx-fallback:requests:#{day}"
      tier = ExecutionDemand.priority(instrument, purpose: Thread.current[:rsc_fallback_purpose])
      now = Time.current
      routine_key = "rsc:fallback-routine:#{day}"
      symbol_key = "rsc:fallback-routine-symbol:#{instrument.id}"
      routine_slot = 'rsc:fallback-routine-slot'
      protection_slot = 'rsc:fallback-protection-slot'
      result = ProviderHttp.evaluate(RESERVE, result_type: Array,
        keys: ['rsc:fx-fallback:slot', total_key, routine_key, symbol_key, routine_slot, protection_slot],
        argv: [RETENTION, tier.to_s, now.to_f.to_s, reason, (now.utc.tomorrow.beginning_of_day-now).ceil])
      raise Error.new('provider_unavailable', status: 503) unless result.first.is_a?(Integer)
      used = result.first
      if used.negative?
        code = {-1=>'provider_busy', -2=>'provider_daily_limit', -3=>'provider_background_budget', -4=>'provider_background_paced'}.fetch(used)
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
          ProviderHttp.evaluate(REFUND,
            keys: [total_key, routine_key, symbol_key, routine_slot, protection_slot],
            argv: [result[4], now.to_f.to_s, now.to_f.to_s, result[1], result[2], result[3], tier.to_s])
          metric(day, instrument.symbol, op, reason, "not_sent:#{code}")
        else
          record_request(day, instrument, op, reason, tier)
          metric(day, instrument.symbol, op, reason, "failed:#{code}")
        end
        raise
      else
        record_request(day, instrument, op, reason, tier)
        metric(day, instrument.symbol, op, reason, 'success')
        value
      end
    end

    def self.report(day = Time.current.utc.to_date)
      key = "rsc:fallback-usage:#{day}"
      { day: day, timezone: 'UTC', total_reserved: Discourse.redis.get("rsc:fx-fallback:requests:#{day}").to_i,
        quote_telemetry: QuoteTelemetry.report(day),
        policy: 'priority_exits', daily_limit: DAILY_LIMIT,
        routine_used: Discourse.redis.get("rsc:fallback-routine:#{day}").to_i, routine_limit: ROUTINE_LIMIT,
        non_priority_ceiling: NON_PRIORITY_CEILING, opening_ceiling: OPENING_CEILING, protection_ceiling: PROTECTION_CEILING, routine_interval: ROUTINE_INTERVAL,
        requests_by_priority: Discourse.redis.hgetall("rsc:fallback-priority:#{day}").transform_values(&:to_i),
        tracked_since: Discourse.redis.get("#{key}:started_at"),
        rows: Discourse.redis.hgetall(key).map { |field, count| symbol, op, reason, outcome = field.split('|'); {symbol: symbol, operation: op, reason: reason, outcome: outcome, count: count.to_i} } }
    end
  end
end
