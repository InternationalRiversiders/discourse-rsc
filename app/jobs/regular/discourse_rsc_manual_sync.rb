# frozen_string_literal: true
module Jobs
  class DiscourseRscManualSync < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled && DiscourseRsc::Access.admin?(User.find_by(id: args[:actor_user_id]))
      result = {}
      DistributedMutex.synchronize("rsc-data-sync", validity: 180) do
        result[:market] = DiscourseRsc::MarketData.sync if SiteSetting.rsc_market_data_enabled
        result[:sports] = DiscourseRsc::SportsData.sync if SiteSetting.rsc_sports_data_enabled
      end
      DiscourseRsc::Audit.create!(actor_user_id: args[:actor_user_id], action: "provider_sync", details: result, created_at: Time.current)
    end
  end
end
