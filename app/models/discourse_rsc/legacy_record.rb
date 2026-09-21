# frozen_string_literal: true
module DiscourseRsc
  class LegacyRecord < ActiveRecord::Base
    self.table_name = "discourse_rsc_legacy_records"
  end
end
