# frozen_string_literal: true
module DiscourseRsc
  class SportMatch < ActiveRecord::Base
    has_many :predictions, class_name: "DiscourseRsc::Prediction", foreign_key: :sport_match_id
    self.table_name = "discourse_rsc_sport_matches"
  end
end
