# frozen_string_literal: true
module DiscourseRsc
  class ForecastTrade < ActiveRecord::Base
    self.table_name = "discourse_rsc_forecast_trades"
    attribute :shares_units, :decimal, precision: 78
    attribute :cash_units, :decimal, precision: 78
    attribute :pnl_units, :decimal, precision: 78
    belongs_to :market, class_name: "DiscourseRsc::ForecastMarket"
  end
end
