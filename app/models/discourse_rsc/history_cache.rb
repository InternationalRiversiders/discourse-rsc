# frozen_string_literal: true
module DiscourseRsc
  class HistoryCache < ActiveRecord::Base
    self.table_name = "discourse_rsc_history_caches"
  end
end
