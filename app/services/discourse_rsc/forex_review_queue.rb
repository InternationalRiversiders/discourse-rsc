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

    def self.watch(id, trading: false)
      Discourse.redis.setex("rsc:fx-review-watch:#{id}", 600, '1')
      Discourse.redis.setex("rsc:fx-review-request:#{id}", 600, '1') if trading
    end

    def self.requested?(id)
      Discourse.redis.exists?("rsc:fx-review-request:#{id}")
    end

    def self.eligible?(id)
      Discourse.redis.exists?("rsc:fx-review-watch:#{id}") || FallbackBudget.exposed?(id)
    end

    def self.enqueue(id)
      ProviderHttp.evaluate(ENQUEUE, keys: [QUEUE], argv: [id.to_s])
    end

    def self.claim
      ProviderHttp.evaluate(CLAIM, keys: [QUEUE, ACTIVE], argv: [TURN_SECONDS])
    end

    def self.turn?(id)
      enqueue(id)
      claim == id
    end

    def self.finish(id, retry_in: 0)
      ProviderHttp.evaluate(FINISH, keys: [QUEUE, ACTIVE], argv: [id.to_s, retry_in])
    end

    def self.next_instrument
      # Recover pending rows predating this queue, or lost Redis state. This is
      # only a database scan. Only held/ordered or recently viewed symbols qualify;
      # unseen catalog quarantine must not continuously spend backup credits.
      Instrument.where(active: true, category: 'forex')
        .where("quote->'verification'->>'status' = 'pending'").pluck(:id).each { |id| enqueue(id) if eligible?(id) }
      id = claim
      return if id.zero?
      item = Instrument.find_by(id: id, active: true, category: 'forex')
      unless item && ForexQuoteGuard.pending?(item.quote) && eligible?(id)
        finish(id)
        return
      end
      if MarketSessions.closed?(item)
        finish(id, retry_in: 300)
        return
      end
      return if Discourse.redis.exists?("rsc:fx-review:#{id}")
      item
    end
  end
end
