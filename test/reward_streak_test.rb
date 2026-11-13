# frozen_string_literal: true
require '/rsc/test/business_test'
require 'active_support/testing/time_helpers'
class RewardStreakTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }
  include ActiveSupport::Testing::TimeHelpers
  def setup
    super
    UserVisit.where(user_id: [@alice.id, @bob.id]).delete_all
    [@alice,@bob].each { |u| u.update_columns(last_seen_at: nil, previous_visit_at: nil) }
  end
  def visits(day, count)
    UserVisit.where(user_id: @alice.id).delete_all
    count.times { |i| UserVisit.create!(user_id: @alice.id, visited_at: day-i, posts_read: 0) }
  end
  def test_streak_steps_cap_and_gap
    day=Date.new(2026,11,14)
    {1=>1,3=>1,4=>2,6=>2,7=>3,27=>9,28=>10,40=>10}.each do |n,expected|
      visits(day,n)
      assert_equal expected,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
    end
    UserVisit.where(user_id:@alice.id,visited_at:day-1).delete_all
    assert_equal 1,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
    UserVisit.where(user_id:@alice.id,visited_at:day).delete_all
    assert_equal 0,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
  end
  def test_streak_effective_business_day_and_historical_visits
    day=Date.new(2026,11,14)
    visits(day,28)
    travel_to(Time.utc(2026,11,13,15,59)) { assert_equal 10,R::Rewards.today(@alice.id)[:daily_max] }
    travel_to(Time.utc(2026,11,13,16,0)) do
      row=R::Rewards.today(@alice.id)
      assert_equal 20,row[:daily_max]
      assert_equal 10,row[:login_reward]
      assert_equal 10,row[:estimated]
    end
    assert_equal 10,R::Rewards.score(day-1,1,30)
    assert_equal 20,R::Rewards.score(day,10,30)
    assert_equal 10,R::Rewards.score(day,0,30)
    assert_equal 11,R::Rewards.score(day,1,30)
  end
  def test_streak_payment_is_idempotent_and_old_dates_keep_old_rules
    day=Date.new(2026,11,14)
    visits(day,28)
    travel_to(Time.utc(2026,11,15,4)) do
      assert_equal 1,R::Rewards.preview((day-1).iso8601).find { |r| r[:user_id]==@alice.id }[:score]
      before=R::Account.wallet(@alice.id).balance_units
      2.times { R::Rewards.pay(day.iso8601) }
      assert_equal 10*R::Amount::UNIT,R::Account.wallet(@alice.id).balance_units-before
    end
  end
  def test_streak_last_seen_fallback_and_no_future_visits
    day=Date.new(2026,11,14)
    visits(day-1,3)
    @alice.update_columns(last_seen_at:Time.utc(2026,11,13,16,1))
    assert_equal 2,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
    @alice.update_columns(last_seen_at:Time.utc(2026,11,14,16,1))
    assert_equal 0,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
  end
end
