# frozen_string_literal: true
module DiscourseRsc
  class ForecastQuote < ActiveRecord::Base
    self.table_name = "discourse_rsc_forecast_quotes"
    attribute :shares_units, :decimal, precision: 78
    attribute :cash_units, :decimal, precision: 78
    belongs_to :market, class_name: "DiscourseRsc::ForecastMarket"
  end
end
