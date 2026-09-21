# frozen_string_literal: true
module Jobs
  class DiscourseRscBusinessTick < ::Jobs::Scheduled
    every 1.minute
    def execute(args)
      return if DiscourseRsc::Safety.read_only?
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      safely("packets") { DiscourseRsc::RedPackets.expire }
      DiscourseRsc::SportMatch.where(status: %w[finished canceled]).joins(:predictions).where(discourse_rsc_predictions: { status: "pending" }).distinct.pluck(:id).each do |id|
        safely("match:#{id}") { DiscourseRsc::Sports.settle(id) }
      end
      if SiteSetting.rsc_campaign_enabled
        safely("campaign") { DiscourseRsc::Campaign.apply if DiscourseRsc::Campaign.preview[:ready] }
      end
      dates = DiscourseRsc::Rewards.catchup_dates
      if SiteSetting.rsc_daily_rewards_enabled && Discourse.redis.set("rsc:rewards-catchup:#{dates.last}", "1", nx: true, ex: 3600)
        # Idempotent per user/date; recover missed jobs after a short outage.
        dates.each do |date|
          safely("rewards:#{date}") { DiscourseRsc::Rewards.pay(date) }
        end
      end
    end
    def safely(label)
      yield
    rescue => error
      Rails.logger.warn("RSC business tick failed for #{label}: #{error.class}")
      DiscourseRsc::Audit.create!(action: "business_tick_failed", details: { item: label, error: error.class.name }, created_at: Time.current)
    end
  end
end
