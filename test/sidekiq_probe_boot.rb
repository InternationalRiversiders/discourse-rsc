# Dedicated worker in a disposable forum; production scheduler code is used,
# but only the plugin's four schedules are discovered in this test process.
abort 'isolated only' unless ENV['RSC_DISPOSABLE_CONTAINER']=='1' && ENV['DISCOURSE_DB_NAME']=='rsc_discourse_smoke'
require '/var/www/discourse/config/environment'
original=MiniScheduler::Manager.method(:discover_schedules)
MiniScheduler::Manager.define_singleton_method(:discover_schedules) do
  original.call.select { |job| %w[Jobs::DiscourseRscBusinessTick Jobs::DiscourseRscDeliverNotifications Jobs::DiscourseRscSyncData Jobs::DiscourseRscTradingTick].include?(job.name) }
end
MiniScheduler.start(workers:1)

# Run promptly in the isolated probe, rather than waiting for first-run jitter.
manager = MiniScheduler::Manager.without_runner
MiniScheduler::Manager.discover_schedules.each do |job|
  info = manager.schedule_info(job)
  info.next_run = Time.now.to_i + 2
  info.write!
end
if ENV['RSC_SIDEKIQ_SLOW_PROBE'] == '1'
  SiteSetting.rsc_crypto_stream_enabled = false
  SiteSetting.rsc_market_data_enabled = true
  DiscourseRsc::MarketData.define_singleton_method(:sync) do
    Discourse.redis.set('rsc:test:slow_started', Time.current.iso8601(6))
    sleep 45
    Discourse.redis.set('rsc:test:slow_finished', Time.current.iso8601(6))
    {}
  end
  Jobs::DiscourseRscTradingTick.prepend(Module.new do
    def execute(args)
      super
      Discourse.redis.rpush('rsc:test:tick_times', Time.current.iso8601(6))
    end
  end)
end
