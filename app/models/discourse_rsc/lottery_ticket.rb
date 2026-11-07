# frozen_string_literal: true
module DiscourseRsc
  class LotteryTicket < ActiveRecord::Base
    self.table_name = 'discourse_rsc_lottery_tickets'
    attribute :payout_units, :decimal, precision: 78
    belongs_to :draw, class_name: 'DiscourseRsc::LotteryDraw'
  end
end
