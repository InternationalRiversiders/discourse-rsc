# frozen_string_literal: true
module DiscourseRsc
  class Dividend < ActiveRecord::Base
    self.table_name = 'discourse_rsc_dividends'
    belongs_to :instrument
    attribute :per_share_units, :decimal, precision: 78
  end
end
