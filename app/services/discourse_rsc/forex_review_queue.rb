# frozen_string_literal: true
module DiscourseRsc
  # A bounded review turn gives one symbol time to collect independent samples.
  # Other requests enqueue instead of racing for the same free-tier credit.
  # Redis state is shared across web/Sidekiq and survives blue-green switches.
  module ForexReviewQueue
    QUEUE = 'rsc:fx-review-queue:v1'
    ACTIVE = 'rsc:fx-review-active:v1'
    TURN_SECONDS = 240
    ENQUEUE = <<~LUA
      redis.call('ZADD', KEYS[1], 'NX', tonumber(redis.call('TIME')[1]), ARGV[1])
      return 1
    LUA
    CLAIM = <<~LUA
      local active = redis.call('GET', KEYS[2])
      if active then return tonumber(active) end
      local now = tonumber(redis.call('TIME')[1])
      local due = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', now, 'LIMIT', 0, 1)
      if #due == 0 then return 0 end
      redis.call('SET', KEYS[2], due[1], 'EX', ARGV[1])
      redis.call('ZADD', KEYS[1], now + tonumber(ARGV[1]), due[1])
      return tonumber(due[1])
    LUA
    FINISH = <<~LUA
      if tonumber(ARGV[2]) > 0 then
        redis.call('ZADD', KEYS[1], tonumber(redis.call('TIME')[1]) + tonumber(ARGV[2]), ARGV[1])
      else
        redis.call('ZREM', KEYS[1], ARGV[1])
      end
      if redis.call('GET', KEYS[2]) == ARGV[1] then redis.call('DEL', KEYS[2]) end
      return 1
    LUA

    def self.eligible?(id)
      ExecutionDemand.automatic?(id)
    end

    def self.enqueue(id)
      ProviderHttp.evaluate(ENQUEUE, keys: [QUEUE], argv: [id.to_s])
    end

    def self.claim
      ProviderHttp.evaluate(CLAIM, keys: [QUEUE, ACTIVE], argv: [TURN_SECONDS])
    end

    def self.turn?(id)
      enqueue(id)
      active = claim
      if active != id && active.positive?
        item = Instrument.find_by(id: id)
        current = Instrument.find_by(id: active)
        priority = item && ExecutionDemand.priority(item, purpose: Thread.current[:rsc_fallback_purpose])
        if %i[exit urgent].include?(priority) && (!current || ExecutionDemand.rank(current) > 0)
          finish(active, retry_in: 60)
          Discourse.redis.zadd(QUEUE, 0, id.to_s)
          active = claim
        end
      end
      active == id
    end

    def self.finish(id, retry_in: 0)
      ProviderHttp.evaluate(FINISH, keys: [QUEUE, ACTIVE], argv: [id.to_s, retry_in])
    end

    def self.next_instrument
      # Recover live trading work only. Old page-view/failed-submission markers
      # cannot spend credits or hold the review lane after the trade disappears.
      Instrument.where(id: ExecutionDemand.instrument_ids, active: true, category: 'forex')
        .where("quote->'verification'->>'status' = 'pending'").to_a.sort_by { |item| ExecutionDemand.rank(item) }.each do |item|
          enqueue(item.id)
          FallbackBudget.with_context(:execution) { turn?(item.id) } if ExecutionDemand.rank(item).zero?
        end
      10.times do
        id = claim
        return if id.zero?
        item = Instrument.find_by(id: id, active: true, category: 'forex')
        unless item && ForexQuoteGuard.pending?(item.quote) && eligible?(id)
          finish(id)
          next
        end
        if MarketSessions.closed?(item)
          finish(id, retry_in: 300)
          next
        end
        return if Discourse.redis.exists?("rsc:fx-review:#{id}")
        return item
      end
      nil
    end
  end
end
