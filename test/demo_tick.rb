# frozen_string_literal: true
# Feeds ONLY explicitly marked demo quotes in a disposable test database.
abort "Isolated test only" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_discourse_smoke"
loop do
  DiscourseRsc::Instrument.where("quote ->> 'demo' = 'true'").find_each do |instrument|
    next if instrument.quote["demo_stale"]
    instrument.with_lock do
      now = Time.current.iso8601(6)
      instrument.update!(quote: instrument.quote.merge("source_time" => now, "received_at" => now))
    end
    DiscourseRsc::Exchange.process(instrument.id)
  end
  DiscourseRsc::Event.where(delivered_at: nil).find_each { |event| DiscourseRsc::NotificationDelivery.deliver(event) }
  sleep 5
end
