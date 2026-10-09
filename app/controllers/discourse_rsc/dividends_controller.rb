# frozen_string_literal: true
module DiscourseRsc
  class DividendsController < WalletController
    skip_before_action :ensure_rsc_member
    before_action { Dividends.admin!(current_user) }
    def index
      records = Dividend.includes(:instrument).order(effective_at: :desc, id: :desc).limit(100)
      render_json_dump(enabled: SiteSetting.rsc_dividends_enabled, rows: records.map { |row| Dividends.view(row) })
    end
    def create
      RateLimiter.new(current_user, 'rsc-dividend-admin', 10, 1.minute).performed!
      instrument = Instrument.find_by!(symbol: params.require(:symbol).to_s.strip.upcase)
      render_json_dump(Dividends.create(actor: current_user, instrument_id: instrument.id,
        ex_date: params.require(:ex_date), amount: params.require(:amount), source_url: params.require(:source_url),
        reason: params.require(:reason), request_id: params.require(:request_id)))
    end
    def review
      RateLimiter.new(current_user, 'rsc-dividend-admin', 10, 1.minute).performed!
      value = params.require(:version).to_s
      raise Error.new('invalid_dividend') unless /\A\d{1,9}\z/.match?(value)
      render_json_dump(Dividends.review(actor: current_user, id: positive_id(:id), decision: params.require(:decision),
        version: value.to_i, request_id: params.require(:request_id)))
    end
  end
end
