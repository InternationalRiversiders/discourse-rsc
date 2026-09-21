# frozen_string_literal: true
module DiscourseRsc
  class Position < ActiveRecord::Base
    self.table_name = "discourse_rsc_positions"
    belongs_to :instrument, class_name: "DiscourseRsc::Instrument"
    %i[quantity_units average_units margin_units take_profit_units stop_loss_units].each { |field| attribute field, :decimal, precision: 78 }
  end
end
