# frozen_string_literal: true
module DiscourseRsc
  class Order < ActiveRecord::Base
    self.table_name = "discourse_rsc_orders"
    belongs_to :instrument, class_name: "DiscourseRsc::Instrument"
    %i[quantity_units reserved_units].each { |field| attribute field, :decimal, precision: 78 }
  end
end
