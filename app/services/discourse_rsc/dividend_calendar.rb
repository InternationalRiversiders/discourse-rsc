# frozen_string_literal: true
module DiscourseRsc
  # Only upcoming, unambiguous USD cash distributions are admitted. Discovery
  # never guesses historic holdings, and an imported plan needs an ex-day check
  # before Exchange may apply it. No network request runs in a trading request.
  module DividendCalendar
    SOURCE = 'nasdaq'
    HOST = 'api.nasdaq.com'
    def self.today
      Time.current.in_time_zone(Dividends::ZONE).to_date
    end

    def self.dates
      pending = Dividend.where(source: SOURCE, status: 'approved').distinct.pluck(:ex_date)
      pending |= (today..today + 14).reject { |date| date.saturday? || date.sunday? } if SiteSetting.rsc_dividends_enabled
      pending.sort
    end

    def self.sync(date)
      date = Date.iso8601(date.to_s)
      return unless dates.include?(date)
      key = "rsc:dividend-calendar:#{date}"
      DistributedMutex.synchronize("#{key}:lock", validity: 120) do
        return if Discourse.redis.get(key)
        response = ProviderHttp.get(HOST, '/api/calendar/dividends', date: date.iso8601)
        ingest(date, response)
        # Refresh today's confirmations hourly; distant dates every six hours.
        Discourse.redis.set(key, '1', ex: date <= today ? 3600 : 21_600)
      end
    end

    def self.parse(date, response)
      calendar = response.dig('data', 'calendar')
      raise Error.new('invalid_dividend_calendar') unless response.dig('status', 'rCode') == 200 && calendar.is_a?(Hash)
      raise Error.new('invalid_dividend_calendar') unless Date.strptime(calendar.fetch('asOf'), '%a, %b %d, %Y') == date
      rows = calendar['rows']
      # A null / unavailable response is not evidence of a canceled dividend.
      raise Error.new('invalid_dividend_calendar') unless rows.is_a?(Array)
      rows.group_by { |row| row.fetch('symbol').to_s }.transform_values do |items|
        begin
          raise Error.new('invalid_dividend_calendar') unless items.size == 1
          row = items.first
          raise Error.new('invalid_dividend_calendar') unless Date.strptime(row.fetch('dividend_Ex_Date'), '%m/%d/%Y') == date
          rate = row.fetch('dividend_Rate')
          rate = rate.to_s('F') if rate.is_a?(BigDecimal)
          Amount.positive(rate.to_s, decimals: 8)
        rescue Error, ArgumentError, KeyError, TypeError
          nil
        end
      end
    rescue ArgumentError, KeyError, TypeError, NoMethodError
      raise Error.new('invalid_dividend_calendar')
    end

    def self.ingest(date, response)
      rows = parse(date, response)
      raise Error.new('invalid_dividend_calendar') if date.saturday? || date.sunday? || date > today + 14
      effective = ActiveSupport::TimeZone[Dividends::ZONE].local(date.year, date.month, date.day, 9, 30)
      Dividend.transaction do
        Commands.lock('rsc-exchange')
        # Match the actual provider symbol, never a translated name or fuzzy ID.
        instruments = Instrument.where(active: true, category: 'us', currency: 'USD').order(:id).lock.to_a
        instruments.each do |instrument|
          next unless Dividends.eligible?(instrument)
          symbol = instrument.provider_symbol.presence || instrument.symbol
          next unless /\A[A-Z][A-Z0-9.-]{0,14}\z/.match?(symbol)
          item = Dividend.find_by(instrument_id: instrument.id, ex_date: date)
          # Manual plans and administrator cancellations are never overwritten.
          next if item && (item.source != SOURCE || item.status != 'approved')
          units = rows[symbol]
          if item
            issue = if units.nil?
              rows.key?(symbol) ? 'invalid_or_duplicate' : 'missing_from_source'
            elsif units != item.per_share_units.to_i && effective <= Time.current
              'changed_after_ex_date'
            end
            if issue
              item.update!(source_issue: issue) unless item.source_issue == issue
              next
            end
          else
            next unless units && SiteSetting.rsc_dividends_enabled
            # First discovery after the cutoff cannot safely reconstruct holdings.
            next unless effective > Time.current
          end
          # >=25% distributions can use special ex-date rules; don't infer them.
          # Re-use the admission check for an unchanged approved amount: a later
          # price drop (including the dividend itself) must not change its class.
          price = BigDecimal(instrument.quote.fetch('price', '0').to_s) rescue BigDecimal('0')
          ordinary = (item && item.per_share_units.to_i == units) ||
            (price.finite? && price.positive? && units * 4 < price * Amount::UNIT)
          unless ordinary
            item&.update!(source_issue: 'unsupported_distribution')
            next
          end
          item ||= Dividend.new(instrument_id: instrument.id, ex_date: date,
            effective_at: effective, source: SOURCE, status: 'approved',
            currency: 'USD', created_by_id: Discourse.system_user.id,
            source_url: "https://www.nasdaq.com/market-activity/dividends?date=#{date.iso8601}",
            reason: 'Nasdaq 分红日历自动同步')
          changed = item.new_record? || item.per_share_units.to_i != units
          item.assign_attributes(per_share_units: units, source_checked_at: Time.current, source_issue: nil)
          item.save!
          Audit.create!(action: 'dividend_auto_scheduled', details: {dividend_id: item.id, source: SOURCE,
            amount: Amount.format(units), ex_date: date}, created_at: Time.current) if changed
        end
      end
    end

    def self.confirmed?(item)
      return true unless item.source == SOURCE
      item.source_issue.nil? && item.source_checked_at &&
        item.source_checked_at.in_time_zone(Dividends::ZONE).to_date >= item.ex_date
    end
  end
end
