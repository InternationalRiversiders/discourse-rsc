# frozen_string_literal: true
require '/rsc/test/business_test'
require 'active_support/testing/time_helpers'
class RewardStreakTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }
  include ActiveSupport::Testing::TimeHelpers
  def setup
    super
    PluginStoreRow.where(plugin_name:R::Rewards::HISTORY_STORE).delete_all
    PluginStoreRow.where("plugin_name LIKE ?", "#{R::Rewards::VISIT_STORE}%").delete_all
    UserVisit.where(user_id: [@alice.id, @bob.id]).delete_all
    [@alice,@bob].each { |u| u.update_columns(created_at:Time.utc(2026,1,1),first_seen_at:nil,last_seen_at: nil, previous_visit_at: nil) }
  end
  def visits(day, count)
    UserVisit.where(user_id: @alice.id).delete_all
    PluginStoreRow.where(plugin_name:"#{R::Rewards::VISIT_STORE}#{@alice.id}").delete_all
    count.times do |i|
      d=day-i
      if d<R::Rewards::VISIT_START
        UserVisit.create!(user_id:@alice.id,visited_at:d,posts_read:0)
      else
        PluginStore.set("#{R::Rewards::VISIT_STORE}#{@alice.id}",d.iso8601,true)
      end
    end
  end
  def snapshot
    data=R::Rewards.legacy_streak_data(R::Rewards::VISIT_START-1,[@alice.id],limit:nil)[@alice.id]
    PluginStore.set(R::Rewards::HISTORY_STORE,@alice.id.to_s,data)
  end
  def test_streak_steps_cap_and_gap
    day=Date.new(2026,11,14)
    {1=>1,3=>1,4=>2,6=>2,7=>3,27=>9,28=>10,40=>10}.each do |n,expected|
      visits(day,n)
      snapshot
      assert_equal expected,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
    end
    travel_to(Time.utc(2026,11,14,4)) { assert_equal 40,R::Rewards.today(@alice.id)[:login_streak] }
    UserVisit.where(user_id:@alice.id,visited_at:day-1).delete_all
    snapshot
    assert_equal 1,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
    assert_equal 1,R::Rewards.login_streaks(day,[@alice.id],limit:nil)[@alice.id]
    UserVisit.where(user_id:@alice.id,visited_at:day).delete_all
    PluginStoreRow.where(plugin_name:"#{R::Rewards::VISIT_STORE}#{@alice.id}",key:day.iso8601).delete_all
    assert_equal 0,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
  end
  def test_streak_effective_business_day_and_historical_visits
    day=Date.new(2026,11,14)
    visits(day,28)
    snapshot
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
    snapshot
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
    snapshot
    @alice.update_columns(last_seen_at:Time.utc(2026,11,13,16,1))
    assert_equal 2,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
    @alice.update_columns(last_seen_at:Time.utc(2026,11,14,16,1))
    assert_equal 0,R::Rewards.login_rewards(day,[@alice.id])[@alice.id]
  end
  def test_streak_beijing_midnight_and_utc_midnight_are_distinct
    travel_to(Time.utc(2026,11,14,15,59)) do
      @alice.update_last_seen!(Time.current,force:true)
      @alice.update_last_seen!(Time.current,force:true)
      assert_equal 1,PluginStoreRow.where(plugin_name:"#{R::Rewards::VISIT_STORE}#{@alice.id}").count
      assert_equal 1,R::Rewards.today(@alice.id)[:login_streak]
    end
    travel_to(Time.utc(2026,11,14,16,1)) do
      assert_equal 1,R::Rewards.today(@alice.id)[:login_streak], 'Keep yesterday streak until a whole day is missed'
      assert_equal 0,R::Rewards.today(@alice.id)[:login_reward]
      assert_equal 0,R::Rewards.login_rewards(Date.new(2026,11,15),[@alice.id])[@alice.id]
      @alice.update_last_seen!(Time.current,force:true)
      assert_equal 2,R::Rewards.today(@alice.id)[:login_streak]
    end
    travel_to(Time.utc(2026,11,15,0,1)) do
      @alice.update_last_seen!(Time.current,force:true)
      assert_equal 2,R::Rewards.today(@alice.id)[:login_streak], 'UTC midnight must not increment the Beijing streak'
    end
    travel_to(Time.utc(2026,11,17,4)) do
      @alice.update_last_seen!(Time.current,force:true)
      assert_equal 1,R::Rewards.today(@alice.id)[:login_streak]
      # A stored visit survives last_seen/previous_visit moving forward.
      assert_includes R::Rewards.visit_ids(Date.new(2026,11,15),Time.utc(2026,11,14,16)),@alice.id
    end
  end

  def test_streak_history_registration_bound_and_timestamp_evidence
    day=Date.new(2026,11,14)
    visits(day,298)
    @alice.update_columns(created_at:Time.utc(2026,1,21,20,10))
    snapshot
    row=R::Rewards.login_streak_data(day,[@alice.id],limit:nil)[@alice.id]
    assert_equal 297,row[:count]
    assert row[:estimated]
    travel_to(Time.utc(2026,11,14,4)) do
      (Date.new(2026,1,22)..day).each { |d| R::Rewards.record_visit(@alice.id,Time.utc(d.year,d.month,d.day)) }
      snapshot
      row=R::Rewards.login_streak_data(day,[@alice.id],limit:nil)[@alice.id]
      assert_equal({count:297,estimated:false},row)
      # UTC-day gaps can be filled by actual Beijing timestamp evidence.
      UserVisit.where(user_id:@alice.id,visited_at:day-2).delete_all
      assert_equal 297,R::Rewards.login_streaks(day,[@alice.id],limit:nil)[@alice.id]
    end
  end

  def test_streak_backfill_uses_actor_time_not_recipient_activity
    stamp=Time.utc(2026,1,22,20)
    UserAction.insert_all!([{action_type:1,user_id:@bob.id,acting_user_id:@alice.id,created_at:stamp,updated_at:stamp}])
    2.times { R::Rewards.backfill_history! }
    assert PluginStoreRow.exists?(plugin_name:"#{R::Rewards::VISIT_STORE}#{@alice.id}",key:'2026-01-23')
    refute PluginStoreRow.exists?(plugin_name:"#{R::Rewards::VISIT_STORE}#{@alice.id}",key:'2026-01-22')
    refute PluginStoreRow.exists?(plugin_name:"#{R::Rewards::VISIT_STORE}#{@bob.id}",key:'2026-01-23')
    assert_equal 1,PluginStoreRow.where(plugin_name:"#{R::Rewards::VISIT_STORE}#{@alice.id}",key:'2026-01-23').count
  end

  def test_streak_timestamp_and_frozen_baseline
    travel_to(Time.utc(2026,11,14,4)) do
      visits(Date.new(2026,11,13),4)
      R::Rewards.initialize_history!
      R::Rewards.record_visit(@alice.id,Time.current)
      R::Rewards.record_visit(@alice.id,Time.current-1.hour)
      R::Rewards.record_visit(@alice.id,Time.current)
      assert_equal (Time.current-1.hour).iso8601(6),PluginStore.get("#{R::Rewards::VISIT_STORE}#{@alice.id}",'2026-11-14')
      before=R::Rewards.login_streaks(Date.new(2026,11,14),[@alice.id],limit:nil)
      UserVisit.where(user_id:@alice.id).delete_all
      R::Rewards.initialize_history!
      assert_equal before,R::Rewards.login_streaks(Date.new(2026,11,14),[@alice.id],limit:nil)
      assert_equal 5,before[@alice.id]
    end
  end

end
