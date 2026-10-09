# frozen_string_literal: true
module DiscourseRsc
  class DividendEntry < ActiveRecord::Base
    self.table_name = 'discourse_rsc_dividend_entries'
    belongs_to :dividend
    %i[quantity_units amount_units].each { |field| attribute field, :decimal, precision: 78 }
  end
end
