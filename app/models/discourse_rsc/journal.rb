# frozen_string_literal: true

module DiscourseRsc
  class Journal < ActiveRecord::Base
    self.table_name = "discourse_rsc_journals"
    has_many :entries, class_name: "DiscourseRsc::Entry", foreign_key: :journal_id
  end
end
