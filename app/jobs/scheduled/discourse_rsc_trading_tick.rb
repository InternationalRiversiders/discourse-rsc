# frozen_string_literal: true
module Jobs
  class DiscourseRscTradingTick < ::Jobs::Scheduled
    every 15.seconds
    def execute(args)
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      return if DiscourseRsc::Safety.read_only?
      DiscourseRsc::CryptoStream.ensure_running
      DistributedMutex.synchronize('rsc-trading-tick', validity: 90) do
        ids = DiscourseRsc::Position.distinct.pluck(:instrument_id) |
          DiscourseRsc::Order.where(status: 'pending').distinct.pluck(:instrument_id)
        # Check available prices before external I/O. Only exposed instruments
        # require risk/order work; an idle catalog does not delay this task.
        ids.each { |id| process(id) }
        DiscourseRscProviderPoll.enqueue_once('crypto')
        Discourse.redis.set('rsc:trading:last_tick', Time.current.iso8601(6), ex: 300)
      end
    end

    def process(id)
      DiscourseRsc::Exchange.process(id)
    rescue StandardError => error
      DiscourseRsc::Audit.create!(action: 'trading_tick_failed', details: {instrument_id: id, error: error.class.name}, created_at: Time.current)
      Rails.logger.warn("RSC trading tick failed: #{error.class}")
    end
  end
end
