# frozen_string_literal: true
module Jobs
  # External I/O runs on the regular queue, leaving the scheduler free to check
  # orders and positions every 15 seconds even during slow provider responses.
  class DiscourseRscProviderPoll < ::Jobs::Base
    MODES = %w[full crypto forex].freeze
    RECOVERY_GRACE = 30
    REAP = <<~LUA
      if redis.call('GET', KEYS[1]) == ARGV[1] and redis.call('GET', KEYS[2]) == ARGV[2] then
        redis.call('DEL', KEYS[1], KEYS[2])
        return 1
      end
      return 0
    LUA

    # Inspect all places a Sidekiq job may legitimately live. A single empty
    # snapshot is insufficient: queue-to-worker bookkeeping has a short gap.
    def self.live_jobs
      jobs = Sidekiq::WorkSet.new.map { |_, _, work| work.job }
      Sidekiq::Queue.all.each { |queue| jobs.concat(queue.to_a) }
      jobs.concat(Sidekiq::RetrySet.new.to_a).concat(Sidekiq::ScheduledSet.new.to_a)
      jobs.map { |job| [job.klass, job.args.first || {}] }
    end

    def self.recover_orphan(key, owner_present:)
      marker = "#{key}:missing-owner"
      token = Discourse.redis.get(key)
      if !token || owner_present
        Discourse.redis.del(marker)
        return false
      end
      observation = Discourse.redis.get(marker)
      seen_token, _, seen_at = observation.to_s.rpartition('|')
      if seen_token != token
        Discourse.redis.set(marker, "#{token}|#{Time.current.to_i}", ex: 120)
        return false
      end
      return false if Time.current.to_i - seen_at.to_i < RECOVERY_GRACE
      DiscourseRsc::ProviderHttp.evaluate(REAP, keys: [key, marker], argv: [token, observation]) == 1
    end

    def self.recover_interrupted(mode)
      key = "rsc:provider-poll:#{mode}"
      return unless Discourse.redis.exists?(key) || (mode == 'full' && Discourse.redis.exists?('rsc-data-sync'))
      # At most one scan per mode/15s across web and worker processes.
      return unless Discourse.redis.set("#{key}:recovery-check", '1', nx: true, ex: 15)
      jobs = live_jobs
      owner = jobs.any? { |klass, args| klass.end_with?('DiscourseRscProviderPoll') && args['mode'] == mode }
      recover_orphan(key, owner_present: owner)
      if mode == 'full'
        manual = jobs.any? { |klass, _| klass.end_with?('DiscourseRscManualSync') }
        # The full poll shares this mutex with manual sync. Never release a
        # queued/running/retrying manual sync's lock, nor a newly replaced lock.
        recover_orphan('rsc-data-sync', owner_present: owner || manual)
      end
    end

    def self.enqueue_once(mode)
      return unless MODES.include?(mode) && SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      return if DiscourseRsc::Safety.read_only?
      recover_interrupted(mode)
      return if mode == 'full' && Discourse.redis.exists?('rsc-data-sync')
      token = SecureRandom.uuid
      key = "rsc:provider-poll:#{mode}"
      return unless Discourse.redis.set(key, token, nx: true, ex: 600)
      Jobs.enqueue(:discourse_rsc_provider_poll, mode: mode, token: token)
    rescue StandardError
      DiscourseRsc::ProviderHttp.evaluate(DiscourseRsc::CryptoStream::RELEASE, keys: [key], argv: [token]) if key && token
      raise
    end

    TRY_DATA_SYNC = <<~LUA
      local now = tonumber(redis.call('TIME')[1])
      local current = redis.call('GET', KEYS[1])
      if current and tonumber(current) >= now then return 0 end
      local expires = now + 600
      redis.call('SETEX', KEYS[1], 601, tostring(expires))
      return expires
    LUA

    def with_data_sync
      expiry = DiscourseRsc::ProviderHttp.evaluate(TRY_DATA_SYNC, keys: ['rsc-data-sync'], argv: [])
      return if expiry.zero?
      begin
        yield
      ensure
        DiscourseRsc::ProviderHttp.evaluate(DiscourseRsc::CryptoStream::RELEASE, keys: ['rsc-data-sync'], argv: [expiry.to_s])
      end
    end

    def execute(args)
      mode = args[:mode]
      return unless MODES.include?(mode)
      key = "rsc:provider-poll:#{mode}"
      return unless args[:token].present? && Discourse.redis.get(key) == args[:token]
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      return if DiscourseRsc::Safety.read_only?
      if mode == 'crypto'
        ids = DiscourseRsc::Position.distinct.pluck(:instrument_id) |
          DiscourseRsc::Order.where(status: 'pending').distinct.pluck(:instrument_id)
        DiscourseRsc::MarketData.sync_crypto(ids).each { |id| Jobs::DiscourseRscTradingTick.new.process(id) }
      elsif mode == 'forex'
        DiscourseRsc::MarketData.sync_forex { |id| Jobs::DiscourseRscTradingTick.new.process(id) }
      else
        # Do not occupy a worker waiting for a possibly abandoned full-sync
        # mutex; a later scheduled scan can recover it when no owner remains.
        with_data_sync do
          DiscourseRsc::MarketData.sync if SiteSetting.rsc_market_data_enabled
          if SiteSetting.rsc_sports_data_enabled && Discourse.redis.set('rsc:sports-poll', '1', nx: true, ex: 300)
            DiscourseRsc::SportsData.sync
          end
        end
      end
    ensure
      DiscourseRsc::ProviderHttp.evaluate(DiscourseRsc::CryptoStream::RELEASE, keys: [key], argv: [args[:token]]) if key && args[:token]
    end
  end
end
