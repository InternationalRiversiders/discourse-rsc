# frozen_string_literal: true
module Jobs
  # External I/O runs on the regular queue, leaving the scheduler free to check
  # orders and positions every 15 seconds even during slow provider responses.
  class DiscourseRscProviderPoll < ::Jobs::Base
    def self.enqueue_once(mode)
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      return if DiscourseRsc::Safety.read_only?
      token = SecureRandom.uuid
      key = "rsc:provider-poll:#{mode}"
      return unless Discourse.redis.set(key, token, nx: true, ex: 600)
      Jobs.enqueue(:discourse_rsc_provider_poll, mode: mode, token: token)
    rescue StandardError
      DiscourseRsc::ProviderHttp.evaluate(DiscourseRsc::CryptoStream::RELEASE, keys: [key], argv: [token]) if key && token
      raise
    end

    def execute(args)
      mode = args[:mode]
      return unless %w[full crypto].include?(mode)
      key = "rsc:provider-poll:#{mode}"
      return unless args[:token].present? && Discourse.redis.get(key) == args[:token]
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      return if DiscourseRsc::Safety.read_only?
      if mode == 'crypto'
        ids = DiscourseRsc::Position.distinct.pluck(:instrument_id) |
          DiscourseRsc::Order.where(status: 'pending').distinct.pluck(:instrument_id)
        DiscourseRsc::MarketData.sync_crypto(ids).each { |id| Jobs::DiscourseRscTradingTick.new.process(id) }
      else
        DistributedMutex.synchronize('rsc-data-sync', validity: 600) do
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
