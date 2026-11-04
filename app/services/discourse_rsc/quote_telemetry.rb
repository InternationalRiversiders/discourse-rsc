# frozen_string_literal: true
module DiscourseRsc
  # Diagnostic counters only. No API keys, account IDs or order parameters.
  # Network observations are distinct from cached replays and guard decisions.
  module QuoteTelemetry
    RETENTION = 14.days.to_i
    OBSERVE = <<~LUA
      local old = redis.call('GET', KEYS[1])
      local incoming = cjson.decode(ARGV[1])
      local outcome = 'first'
      if old then
        local previous = cjson.decode(old)
        if incoming.at < previous.at then outcome = 'regression'
        elseif incoming.at == previous.at then
          outcome = incoming.price == previous.price and 'duplicate' or 'revision'
        else outcome = 'new_timestamp' end
      end
      if outcome ~= 'regression' then redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[3]) end
      redis.call('HINCRBY', KEYS[2], ARGV[2]..'|response|'..outcome, 1)
      redis.call('HINCRBY', KEYS[2], ARGV[2]..'|freshness|'..ARGV[4], 1)
      redis.call('EXPIRE', KEYS[2], ARGV[3])
      redis.call('SET', KEYS[3], ARGV[5], 'NX', 'EX', ARGV[3])
      return 1
    LUA

    def self.key(day = Time.current.utc.to_date)
      "rsc:quote-telemetry:#{day}"
    end

    def self.prefix(instrument, quote, operation = nil)
      [instrument.symbol, quote.fetch('source'), operation || FallbackBudget.operation(instrument)].join('|')
    end

    def self.safely
      yield
    rescue StandardError => e
      Rails.logger.warn("[rsc] quote telemetry unavailable: #{e.class}")
      nil
    end

    # Call only after a real provider response, before checking its freshness.
    def self.response(instrument, quote)
      safely do
        at = Time.iso8601(quote.fetch('source_time'))
        freshness = at > 5.seconds.from_now ? 'future' : ForexQuoteGuard.fresh?(quote) ? 'fresh' : 'stale'
        ProviderHttp.evaluate(OBSERVE,
          keys: ["rsc:quote-observation:#{instrument.id}:#{quote.fetch('source')}", key, "#{key}:started_at"],
          argv: [{at: at.to_f, price: Amount.format(Amount.positive(quote.fetch('price')))}.to_json,
                 prefix(instrument, quote), RETENTION, freshness, Time.current.iso8601(6)])
      end
    end

    def self.count(instrument, quote, stage, outcome, operation: nil)
      safely do
        Discourse.redis.hincrby(key, [prefix(instrument, quote, operation), stage, outcome].join('|'), 1)
        Discourse.redis.expire(key, RETENTION)
        Discourse.redis.set("#{key}:started_at", Time.current.iso8601(6), nx: true, ex: RETENTION)
      end
    end

    def self.identity(quote)
      quote.slice('source', 'source_time', 'price')
    end

    def self.decision(instrument, incoming, result, previous: instrument.quote, stage: 'decision')
      safely do
        outcome = if result.nil?
          'rejected_stale'
        elsif ForexQuoteGuard.pending?(result)
          'pending_review'
        elsif identity(result) != identity(incoming)
          'source_retained'
        elsif identity(result) == identity(previous)
          'accepted_repeat'
        else
          'adopted'
        end
        completed = ForexQuoteGuard.pending?(previous) && result && !ForexQuoteGuard.pending?(result)
        method = result&.dig('verification', 'method') || 'unknown'
        operation = FallbackBudget.operation(instrument)
        # A rolled-back database write is not an adopted quote. Preserve the
        # request purpose if an outer transaction commits after its context exits.
        ActiveRecord.after_all_transactions_commit do
          count(instrument, incoming, stage, outcome, operation: operation)
          count(instrument, incoming, stage == 'decision' ? 'review_completed' : 'automatic_review_completed', method, operation: operation) if completed
        end
      end
    end

    def self.report(day = Time.current.utc.to_date)
      { tracked_since: Discourse.redis.get("#{key(day)}:started_at"),
        rows: Discourse.redis.hgetall(key(day)).map do |field, count|
          symbol, source, operation, stage, outcome = field.split('|')
          {symbol: symbol, source: source, operation: operation, stage: stage, outcome: outcome, count: count.to_i}
        end }
    end
  end
end
