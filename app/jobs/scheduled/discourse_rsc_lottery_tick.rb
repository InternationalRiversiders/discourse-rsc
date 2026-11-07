# frozen_string_literal: true
module Jobs
  class DiscourseRscLotteryTick < ::Jobs::Scheduled
    every 1.minute
    def execute(args)
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      DiscourseRsc::Lottery.tick
    end
  end
end
