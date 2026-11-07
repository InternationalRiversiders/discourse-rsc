# frozen_string_literal: true
require '/rsc/test/business_test'
require 'active_support/testing/time_helpers'
class ArcadeTest < NativeBusinessTest
  include ActiveSupport::Testing::TimeHelpers
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |n| undef_method n }
  def setup
    super
    R::ArcadeRun.delete_all;R::ArcadePeriod.delete_all
    SiteSetting.rsc_arcade_rotation_cadence='weekly'
    SiteSetting.rsc_games_enabled=true;SiteSetting.rsc_arcade_enabled=true;SiteSetting.rsc_arcade_rewards_enabled=false
    fund(@alice,'100');fund(@bob,'100')
  end
  def start(game='2048',actor:@alice,key:SecureRandom.uuid)
    R::Arcade.start(actor:actor,game:game,request_id:key)
  end
  def advance(run,**args)
    R::Arcade.advance(**{actor:@alice,id:run[:id],version:run[:version],request_id:SecureRandom.uuid,frames:1,events:[[0,'l']]}.merge(args))
  end
  def test_start_resume_and_duplicate_do_not_charge_or_reset
    key=SecureRandom.uuid;r=start(key:key);assert_equal r,start(key:key);assert_equal r,start
    assert_equal '100',R::Account.wallet(@alice.id).balance
    assert_equal 1,R::ArcadeRun.count
    assert_raises(R::Error) {start('bird',key:key)}
    refute r[:state].key?('q')
    refute JSON.generate(r).include?('seed')
  end
  def test_verified_score_and_duplicate_checkpoint
    r=start;key=SecureRandom.uuid
    s=advance(r,request_id:key);again=advance(r,request_id:key)
    assert_equal s,again
    assert_equal 1,R::ArcadeRun.find(r[:id]).version
    assert_raises(R::Error) {advance(r,request_id:key,events:[[0,'r']])}
    assert_raises(R::Error) {advance(r)}
    assert_raises(ActiveRecord::RecordNotFound) {advance(s,actor:@bob)}
    assert_raises(R::Error) {advance(s,frames:999999)}
    assert_raises(R::Error) {advance(s,events:[[0,'score:999']])}
    assert_raises(R::Error) {advance(s,version:'1')}
  end
  def test_saved_replay_reproduces_all_seven_games
    R::Arcade::NAMES.each_key do |game|
      r=start(game)
      r=advance(r,frames:game=='2048' ? 1 : 20,events:game=='2048' ? [[0,'l']] : [])
      row=R::ArcadeRun.find(r[:id]);replay=R::Arcade.engine('create',game,row.inputs.first['initial'])
      row.inputs.drop(1).each do |batch|
        replay=R::Arcade.engine('advance',replay,batch['frames'],batch['events']);replay['q'].concat(batch['refill'])
      end
      assert_equal row.state,replay
      assert_equal row.score,replay['score']
    end
  end
  def test_finish_is_single_and_leaderboard_best_per_user
    r=start;r=advance(r,finish:true)
    assert_equal 'finished',r[:status]
    assert_raises(R::Error) {advance(r)}
    p=R::ArcadePeriod.find(r[:period_id])
    R::ArcadeRun.find(r[:id]).update!(score:120)
    second=start;advance(second,finish:true);R::ArcadeRun.find(second[:id]).update!(score:80)
    bob=start(actor:@bob);advance(bob,actor:@bob,finish:true);R::ArcadeRun.find(bob[:id]).update!(score:120)
    assert_equal [[@alice.id,120],[@bob.id,120]].sort,R::Arcade.ranked(p,'2048').sort
    R::Account.wallet(@bob.id).update!(status:'frozen')
    assert_equal [[@alice.id,120]],R::Arcade.ranked(p,'2048')
  end
  def test_expiry_freeze_and_disabled_reject_actions
    r=start;R::ArcadeRun.find(r[:id]).update!(expires_at:1.second.ago)
    assert_raises(R::Error) {advance(r)}
    r=start;refute_equal r[:id],R::ArcadeRun.where(status:'expired').first.id
    R::Account.wallet(@alice.id).update!(status:'frozen');assert_raises(R::Error) {advance(r)}
    SiteSetting.rsc_arcade_enabled=false;assert_raises(R::Error) {start}
  end
  def test_rewards_off_settles_without_any_money_change
    r=start;advance(r,finish:true);R::ArcadeRun.find(r[:id]).update!(score:100)
    p=R::ArcadePeriod.find(r[:period_id]);assert_empty p.prizes
    count=R::Journal.count;travel_to(p.ends_at+1.second) { R::Arcade.settle;R::Arcade.settle }
    assert p.reload.settled_at;assert_equal count,R::Journal.count;assert_equal '100',R::Account.wallet(@alice.id).balance
  end
  def test_prize_ties_and_retry_are_bounded
    SiteSetting.rsc_arcade_rewards_enabled=true
    r=start;advance(r,finish:true);R::ArcadeRun.find(r[:id]).update!(score:100)
    b=start(actor:@bob);advance(b,actor:@bob,finish:true);R::ArcadeRun.find(b[:id]).update!(score:100)
    p=R::ArcadePeriod.find(r[:period_id])
    travel_to(p.ends_at+1.second) { R::Arcade.settle;R::Arcade.settle }
    assert_equal '180',R::Account.wallet(@alice.id).balance
    assert_equal '180',R::Account.wallet(@bob.id).balance
    assert_equal 1,R::Journal.where(operation:'arcade_prize').count
  end
  def test_node_and_embedded_v8_match_exactly
    JSON.parse(File.read("/rsc/test/arcade/fixtures.json")).each do |f|
      assert_equal f["expected"],R::Arcade.engine("advance",f["initial"],f["frames"],f["events"]),f["game"]
    end
  end
  def test_week_boundary_is_beijing_sunday_twenty
    assert_equal Time.utc(2026,11,8,12),R::Arcade.end_time(Time.utc(2026,11,8,11,59,59))
    assert_equal Time.utc(2026,11,15,12),R::Arcade.end_time(Time.utc(2026,11,8,12))
  end
  def test_only_featured_game_awards_and_all_time_survives_rotation
    SiteSetting.rsc_arcade_rewards_enabled=true
    a=start;advance(a,finish:true);R::ArcadeRun.find(a[:id]).update!(score:200)
    other=start('bird');advance(other,frames:1,events:[],finish:true);R::ArcadeRun.find(other[:id]).update!(score:999)
    p=R::ArcadePeriod.find(a[:period_id])
    assert_equal p.id,a[:season_id];assert_nil other[:season_id]
    assert_nil R::Arcade.ranking(@alice,'bird')[:season]
    travel_to(p.ends_at+1.second) do
      R::Arcade.settle
      current=R::Arcade.period
      assert_equal 'blocks',current.game
      assert_equal 2,current.ordinal
      assert_equal 7.days,current.ends_at-current.starts_at
      assert_equal '200',R::Account.wallet(@alice.id).balance
      assert_equal [[@alice.id,200]],R::Arcade.ranked(nil,'2048')
      assert_nil R::Arcade.ranking(@alice,'2048')[:season]
      assert_equal 1,R::Arcade.ranking(@alice,'2048')[:previous][:number]
    end
  end
  def test_cadence_changes_only_next_season_and_wraps_games
    p=R::Arcade.period
    SiteSetting.rsc_arcade_rotation_cadence='daily'
    assert_equal p.id,R::Arcade.period.id
    assert_equal 'weekly',p.reload.cadence
    travel_to(p.ends_at+1.second) do
      next_p=R::Arcade.period
      assert_equal 'daily',next_p.cadence
      assert_equal 1.day,next_p.ends_at-next_p.starts_at
      assert_equal 'blocks',next_p.game
    end
    travel_to(p.ends_at+6.days+1.second) do
      p2=R::Arcade.period
      assert_equal '2048',p2.game
      assert_equal 8,p2.ordinal
    end
  end
  def test_nonseason_run_cannot_enter_next_season_but_can_finish_for_all_time
    p=R::Arcade.period
    run=nil
    travel_to(p.ends_at-5.minutes) { run=start('blocks') }
    travel_to(p.ends_at+1.minute) do
      next_p=R::Arcade.period
      resumed=start('blocks')
      assert_equal run[:id],resumed[:id]
      assert_nil resumed[:season_id]
      result=advance(resumed,frames:1,events:[],finish:true)
      R::ArcadeRun.find(result[:id]).update!(score:500)
      assert_empty R::Arcade.ranked(next_p,'blocks')
      assert_equal [[@alice.id,500]],R::Arcade.ranked(nil,'blocks')
      fresh=start('blocks');assert_equal next_p.id,fresh[:season_id]
    end
  end
  def test_trial_period_never_gains_rewards_and_old_scores_stay_in_total
    legacy=R::ArcadePeriod.create!(ends_at:1.minute.ago,prizes:R::Arcade::PRIZES)
    run=start;advance(run,finish:true)
    R::ArcadeRun.find(run[:id]).update!(period_id:legacy.id,score:99)
    count=R::Journal.count;R::Arcade.settle
    assert_equal count,R::Journal.count
    assert_equal [[@alice.id,99]],R::Arcade.ranked(nil,'2048')
  end

end
