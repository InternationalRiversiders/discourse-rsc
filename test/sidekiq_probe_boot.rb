# Dedicated worker in a disposable forum; production scheduler code is used,
# but only the plugin's three schedules are discovered in this test process.
abort 'isolated only' unless ENV['RSC_DISPOSABLE_CONTAINER']=='1' && ENV['DISCOURSE_DB_NAME']=='rsc_discourse_smoke'
require '/var/www/discourse/config/environment'
original=MiniScheduler::Manager.method(:discover_schedules)
MiniScheduler::Manager.define_singleton_method(:discover_schedules) do
  original.call.select { |job| %w[Jobs::DiscourseRscBusinessTick Jobs::DiscourseRscDeliverNotifications Jobs::DiscourseRscSyncData Jobs::DiscourseRscTradingTick].include?(job.name) }
end
MiniScheduler.start(workers:1)
