# frozen_string_literal: true
module Jobs
  class DiscourseRscNotify < ::Jobs::Base
    def execute(args)
      return if DiscourseRsc::Safety.read_only? || !SiteSetting.rsc_enabled || !SiteSetting.rsc_notifications_enabled
      event = DiscourseRsc::Event.find_by(id: args[:event_id])
      DiscourseRsc::NotificationDelivery.attempt(event) if event && !event.delivered_at
    end
  end
end
