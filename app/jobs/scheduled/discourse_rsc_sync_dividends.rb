# frozen_string_literal: true
module Jobs
  class DiscourseRscSyncDividends < ::Jobs::Scheduled
    every 1.hour
    def execute(args)
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled
      return if DiscourseRsc::Safety.read_only?
      DiscourseRsc::DividendCalendar.dates.each_with_index do |date, index|
        Jobs.enqueue_in(index * 30.seconds, :discourse_rsc_dividend_calendar, date: date.iso8601)
      end
    end
  end
end
