# frozen_string_literal: true
module DiscourseRsc
  class Prediction < ActiveRecord::Base
    self.table_name = "discourse_rsc_predictions"
    belongs_to :sport_match, class_name: "DiscourseRsc::SportMatch"
    %i[stake_units payout_units].each { |field| attribute field, :decimal, precision: 78 }
  end
end
