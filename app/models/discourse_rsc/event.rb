# frozen_string_literal: true

module DiscourseRsc
  class Event < ActiveRecord::Base
    self.table_name = "discourse_rsc_events"
    belongs_to :journal, class_name: "DiscourseRsc::Journal"
    after_create_commit :enqueue_notification
    def enqueue_notification
      return unless defined?(Jobs) && defined?(SiteSetting) && SiteSetting.rsc_notifications_enabled
      return if delivered_at || DiscourseRsc::Safety.read_only?
      Jobs.enqueue(:discourse_rsc_notify, event_id: id)
    rescue StandardError => error
      # The committed outbox remains authoritative; the scheduled worker retries.
      Rails.logger.warn("RSC notification enqueue event=#{id}: #{error.class.name}") if defined?(Rails)
    end
    scope :due, -> { where(delivered_at: nil).where("next_attempt_at <= ?", Time.current) }
  end
end
