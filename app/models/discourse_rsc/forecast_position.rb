# frozen_string_literal: true
module DiscourseRsc
  class ForecastPosition < ActiveRecord::Base
    self.table_name = "discourse_rsc_forecast_positions"
    attribute :shares_units, :decimal, precision: 78
    attribute :cost_units, :decimal, precision: 78
    attribute :realized_units, :decimal, precision: 78
    belongs_to :market, class_name: "DiscourseRsc::ForecastMarket"
  end
end
