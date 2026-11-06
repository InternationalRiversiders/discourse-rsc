# frozen_string_literal: true
module DiscourseRsc
  class GameRound < ActiveRecord::Base
    self.table_name = 'discourse_rsc_game_rounds'
    %i[stake_units payout_units].each { |field| attribute field, :decimal, precision: 78 }
  end
end
