# frozen_string_literal: true

module Jobs
  class DiscourseRscDeliverNotifications < ::Jobs::Scheduled
    every 1.minute

    def execute(args)
      return if DiscourseRsc::Safety.read_only?
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_notifications_enabled
      ::DiscourseRsc::Event.due.order(:id).limit(100).each do |event|
        ::DiscourseRsc::NotificationDelivery.attempt(event)
      end
    end
  end
end
