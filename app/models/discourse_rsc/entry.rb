# frozen_string_literal: true

module DiscourseRsc
  class Entry < ActiveRecord::Base
    self.table_name = "discourse_rsc_entries"
    attribute :units, :decimal, precision: 78
    attribute :balance_after_units, :decimal, precision: 78
    belongs_to :journal, class_name: "DiscourseRsc::Journal"
    belongs_to :account, class_name: "DiscourseRsc::Account"
  end
end
