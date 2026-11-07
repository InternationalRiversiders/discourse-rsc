# frozen_string_literal: true
module DiscourseRsc
  class LotteryDraw < ActiveRecord::Base
    self.table_name = 'discourse_rsc_lottery_draws'
    %i[pool_units paid_units small_paid_units].each { |field| attribute field, :decimal, precision: 78 }
  end
end
