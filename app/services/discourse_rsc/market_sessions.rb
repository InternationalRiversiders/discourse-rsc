# frozen_string_literal: true
module DiscourseRsc
  module MarketSessions
    def self.hours
      Discourse.cache.fetch('rsc:trading-hours', expires_in: 5.minutes) do
        LegacyRecord.where(source_table: 'market_instruments').pluck(:data).to_h { |row| [row['symbol'], row['trading_hours']] }
      end
    end

    # Local sessions retain lunch breaks and DST; provider windows can additionally
    # close a session for holidays, but cannot open a locally closed market.
    def self.closed?(instrument, now = Time.current, schedules: nil)
      return false if instrument.category == 'crypto'
      schedule = (schedules || hours)[instrument.symbol].to_s.strip
      return false if schedule == '24/7'
      if instrument.category == 'forex' || schedule == '24/5'
        local = now.in_time_zone('America/New_York')
        return local.saturday? || (local.sunday? && local.hour < 17) || (local.friday? && local.hour >= 17)
      end
      sessions, _, zone = schedule.rpartition(' ')
      if sessions.present? && zone.present?
        local = now.in_time_zone(zone)
        windows = sessions.split(',').filter_map do |part|
          match = /\A(\d{2}):(\d{2})-(\d{2}):(\d{2})\z/.match(part.strip)
          next unless match
          a, b, c, d = match.captures.map(&:to_i)
          next unless a < 24 && c < 24 && b < 60 && d < 60 && a * 60 + b < c * 60 + d
          [a * 60 + b, c * 60 + d]
        end
        unless windows.empty?
          minute = local.hour * 60 + local.min
          return true if local.saturday? || local.sunday? || windows.none? { |start, finish| minute >= start && minute < finish }
        end
      end
      q = instrument.quote
      received = Time.iso8601(q.fetch('received_at'))
      return false unless received <= now + 5 && received >= now - 300
      start = Time.iso8601(q.fetch('session_start'))
      finish = Time.iso8601(q.fetch('session_end'))
      now < start || now >= finish
    rescue ArgumentError, KeyError
      false # Unknown sessions need a provider refresh, not a permanent skip.
    end
  end
end
