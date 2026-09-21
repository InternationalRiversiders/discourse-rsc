# frozen_string_literal: true
module DiscourseRsc
  class Audit < ActiveRecord::Base
    self.table_name = "discourse_rsc_audits"
  end
end
