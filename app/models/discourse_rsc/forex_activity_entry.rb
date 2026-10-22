# frozen_string_literal: true
module DiscourseRsc
  class ForexActivityEntry < ActiveRecord::Base
    self.table_name = 'discourse_rsc_forex_activity_entries'
    belongs_to :instrument, class_name: 'DiscourseRsc::Instrument'
    %i[realized_units mark_units mark_price_units final_units].each { |field| attribute field, :decimal, precision: 78 }
  end
end
