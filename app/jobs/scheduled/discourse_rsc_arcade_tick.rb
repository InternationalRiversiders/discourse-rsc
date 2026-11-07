# frozen_string_literal: true
module Jobs
  class DiscourseRscArcadeTick < ::Jobs::Scheduled
    every 5.minutes
    def execute(args)
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      DiscourseRsc::Arcade.settle
    end
  end
end
