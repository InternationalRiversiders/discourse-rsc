# frozen_string_literal: true
module DiscourseRsc
  class Instrument < ActiveRecord::Base
    self.table_name = "discourse_rsc_instruments"
    attribute :minimum_units, :decimal, precision: 78
    attribute :step_units, :decimal, precision: 78
    validates :symbol, :name, presence: true
    validates :fee_bps, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1000 }
  end
end
