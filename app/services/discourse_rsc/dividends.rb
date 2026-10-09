# frozen_string_literal: true
require 'uri'
module DiscourseRsc
  # Signed entitlements are included in equity and settled through the ledger
  # on close, never credited separately to the wallet and double-counted.
  module Dividends
    ZONE = 'America/New_York'
    def self.eligible?(instrument)
      instrument.active && instrument.category == 'us' && instrument.currency == 'USD' &&
        %w[stock etf fund].include?(instrument.asset_type) && !TradingRules.close_only?(instrument)
    end

    def self.admin!(actor)
      raise Error.new('admin_required', status: 403) unless Access.admin?(actor)
    end

    def self.enabled!
      raise Error.new('dividends_disabled', status: 403) unless SiteSetting.rsc_dividends_enabled
    end

    def self.create(actor:, instrument_id:, ex_date:, amount:, source_url:, reason:, request_id:)
      admin!(actor); enabled!
      raise Error.new('invalid_dividend') unless /\A\d{4}-\d{2}-\d{2}\z/.match?(ex_date.to_s)
      day = Date.iso8601(ex_date)
      effective = ActiveSupport::TimeZone[ZONE].local(day.year, day.month, day.day, 9, 30)
      raise Error.new('dividend_too_late') unless effective > Time.current && effective < 180.days.from_now && !day.saturday? && !day.sunday?
      units = Amount.positive(amount, decimals: 8)
      url = URI.parse(source_url.to_s)
      raise Error.new('invalid_dividend') unless url.is_a?(URI::HTTPS) && url.host.present? && !url.userinfo && source_url.bytesize <= 500
      raise Error.new('reason_required') unless reason.is_a?(String) && reason.strip.length.between?(1, 500)
      Commands.run(user_id: actor.id, action: 'dividend_create', request_id: request_id,
        input: [instrument_id, ex_date, amount, source_url, reason]) do
        Commands.lock('rsc-exchange')
        raise Error.new('dividend_too_late') unless effective > Time.current
        instrument = Instrument.lock.find(instrument_id)
        raise Error.new('dividend_ineligible') unless eligible?(instrument)
        item = Dividend.find_or_initialize_by(instrument_id: instrument.id, ex_date: day)
        raise Error.new('dividend_locked') if item.persisted? && !%w[draft canceled].include?(item.status)
        item.assign_attributes(effective_at: effective, per_share_units: units, source_url: source_url,
          reason: reason.strip, created_by_id: actor.id, reviewed_by_id: nil, status: 'draft')
        item.save!
        Audit.create!(actor_user_id: actor.id, action: 'dividend_draft', details: {dividend_id: item.id}, created_at: Time.current)
        view(item)
      end
    rescue Date::Error, URI::InvalidURIError
      raise Error.new('invalid_dividend')
    end

    def self.review(actor:, id:, decision:, version:, request_id:)
      admin!(actor)
      raise Error.new('invalid_dividend') unless %w[approved canceled].include?(decision)
      enabled! if decision == 'approved'
      Commands.run(user_id: actor.id, action: 'dividend_review', request_id: request_id, input: [id, decision, version]) do
        Commands.lock('rsc-exchange')
        item = Dividend.lock.find(id)
        raise Error.new('dividend_locked', status: 409) unless item.lock_version == version && %w[draft approved].include?(item.status)
        raise Error.new('dividend_too_late') unless item.effective_at > Time.current
        raise Error.new('dividend_ineligible') if decision == 'approved' && !eligible?(item.instrument)
        item.update!(status: decision, reviewed_by_id: actor.id)
        Audit.create!(actor_user_id: actor.id, action: "dividend_#{decision}", details: {dividend_id: item.id, amount: Amount.format(item.per_share_units), ex_date: item.ex_date}, created_at: Time.current)
        view(item)
      end
    end

    def self.due(instrument)
      Dividend.where(instrument_id: instrument.id, status: 'approved').where('effective_at <= ?', Time.current).order(:effective_at, :id)
    end

    # Requires exchange/instrument locks; called before fills and liquidation.
    # Approved obligations survive the switch which disables NEW scheduling.
    def self.apply_due!(instrument)
      due(instrument).lock.each do |item|
        raise Error.new('dividend_ineligible') unless eligible?(instrument)
        source = Time.iso8601(instrument.quote.fetch('source_time'))
        raise Error.new('dividend_pending', status: 409) if source < item.effective_at
        Order.where(instrument_id: instrument.id, status: 'pending').order(:id).each do |order|
          Exchange.send(:refund_locked, order, 'canceled', 'dividend_adjustment')
        end
        Position.where(instrument_id: instrument.id).order(:id).lock.each do |position|
          raise Error.new('dividend_inconsistent') if position.created_at >= item.effective_at
          signed = position.quantity_units.to_i * item.per_share_units.to_i / Amount::UNIT
          signed = -signed if position.side == 'short'
          next if signed.zero?
          changes = {dividend_units: position.dividend_units.to_i + signed}
          %i[take_profit_units stop_loss_units].each do |field|
            next unless position.public_send(field)
            shifted = position.public_send(field).to_i - item.per_share_units.to_i
            changes[field] = shifted.positive? ? shifted : nil
          end
          position.update!(changes)
          DividendEntry.create!(dividend_id: item.id, position_id: position.id, user_id: position.user_id,
            side: position.side, quantity_units: position.quantity_units, amount_units: signed, created_at: Time.current)
        end
        item.update!(status: 'applied', applied_at: Time.current)
        Audit.create!(action: 'dividend_applied', details: {dividend_id: item.id, entries: DividendEntry.where(dividend_id: item.id).count}, created_at: Time.current)
      end
    end

    # Truncate signed allocations towards zero; final close gets the remainder.
    def self.portion(position, quantity = position.quantity_units.to_i)
      total = position.dividend_units.to_i
      value = total.abs * quantity / position.quantity_units.to_i
      total.negative? ? -value : value
    end

    def self.view(item)
      {id: item.id, instrument_id: item.instrument_id, symbol: item.instrument.symbol, ex_date: item.ex_date,
        effective_at: item.effective_at, amount: Amount.format(item.per_share_units), currency: item.currency,
        status: item.status, source_url: item.source_url, reason: item.reason, version: item.lock_version,
        applied_at: item.applied_at}
    end

    def self.history(user_id)
      DividendEntry.where(user_id: user_id).includes(dividend: :instrument).order(id: :desc).limit(50).map do |row|
        {id: row.id, symbol: row.dividend.instrument.symbol, ex_date: row.dividend.ex_date,
          quantity: Amount.format(row.quantity_units), side: row.side, amount: Amount.format(row.amount_units)}
      end
    end
  end
end
