# frozen_string_literal: true
module Jobs
  class DiscourseRscDividendCalendar < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      return if DiscourseRsc::Safety.read_only?
      DiscourseRsc::DividendCalendar.sync(args.fetch(:date))
    end
  end
end
