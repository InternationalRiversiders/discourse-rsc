# frozen_string_literal: true
module DiscourseRsc
  class ForecastRequest < ActiveRecord::Base
    self.table_name = 'discourse_rsc_forecast_requests'
    scope :approved_markets, -> { where(status: 'approved').where.not(market_id: nil).select(:market_id) }
  end
end
