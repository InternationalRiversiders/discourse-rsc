# frozen_string_literal: true
require '/rsc/test/business_test'
require 'active_support/testing/time_helpers'
class ArcadeTest < NativeBusinessTest
  include ActiveSupport::Testing::TimeHelpers
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |n| undef_method n }
  def setup
    super
    R::ArcadeRun.delete_all;R::ArcadePeriod.delete_all
    R::Arcade::NAMES.each_key { |game| Rails.cache.delete(R::Arcade.rank_cache_key(nil,game)) }
    SiteSetting.rsc_arcade_rotation_cadence='weekly'
    SiteSetting.rsc_games_enabled=true;SiteSetting.rsc_arcade_enabled=true;SiteSetting.rsc_arcade_rewards_enabled=false
    fund(@alice,'100');fund(@bob,'100')
  end
  def start(game='2048',actor:@alice,key:SecureRandom.uuid)
    R::Arcade.start(actor:actor,game:game,request_id:key,rules_version:2)
  end
  def advance(run,**args)
    R::Arcade.advance(**{actor:@alice,id:run[:id],version:run[:version],request_id:SecureRandom.uuid,frames:1,events:[[0,'l']],rules_version:2}.merge(args))
  end
  def test_new_physics_resume_keeps_score_and_rejects_old_client_writes
    old=start('merge');old=advance(old,frames:30,events:[[0,'drop']])
    modern=R::Arcade.start(actor:@alice,game:'merge',request_id:SecureRandom.uuid,rules_version:3)
    assert_equal old[:id],modern[:id]
    assert_equal old[:state]['score'],modern[:state]['score']
    assert_equal old[:state]['balls'],modern[:state]['balls']
    assert_equal 3,modern[:state]['version']
    assert_equal old[:version]+1,modern[:version]
    assert_raises(R::Error){advance(modern,events:[])}
    updated=advance(modern,events:[],rules_version:3)
    assert updated[:state]['balls'].all?{|b| b.key?('spin') && b.key?('angle')}
    duplicate=R::ArcadeRun.find(modern[:id]).inputs.first
    assert duplicate['checkpoint']
  end
  def test_v4_upgrade_preserves_v3_save_and_uses_current_rules
    old=R::Arcade.start(actor:@alice,game:'merge',request_id:SecureRandom.uuid,rules_version:3)
    old=advance(old,frames:60,events:[[0,'drop']],rules_version:3)
    current=R::Arcade.start(actor:@alice,game:'merge',request_id:SecureRandom.uuid,rules_version:4)
    assert_equal old[:id],current[:id]
    assert_equal old[:state]['score'],current[:state]['score']
    assert_equal old[:state]['balls'],current[:state]['balls']
    assert_equal 4,current[:state]['version']
    assert_raises(R::Error){advance(current,events:[],rules_version:3)}
    updated=advance(current,frames:120,events:[],rules_version:4)
    assert updated[:state]['balls'].all?{|b| b['precise'].size==6 && b['precise'].all?{|n| n.is_a?(Integer)}}
    run=R::ArcadeRun.find(current[:id])
    assert_equal run.state,R::Arcade.engine('advance',run.inputs.first['checkpoint'],120,[]).tap{|v| v['q']=run.state['q']}
  end
  def test_start_resume_and_duplicate_do_not_charge_or_reset
    key=SecureRandom.uuid;r=start(key:key);assert_equal r,start(key:key);assert_equal r,start
    assert_equal '100',R::Account.wallet(@alice.id).balance
    assert_equal 1,R::ArcadeRun.count
    assert_raises(R::Error) {start('bird',key:key)}
    assert_equal 20,r[:state]['q'].length
    refute JSON.generate(r).include?('seed')
  end
  def test_verified_score_and_duplicate_checkpoint
    r=start;key=SecureRandom.uuid
    s=advance(r,request_id:key,rules_version:2);again=advance(r,request_id:key,rules_version:2)
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
      row=R::ArcadeRun.find(r[:id]);replay=R::Arcade.engine('create',game,row.inputs.first['initial'],row.inputs.first['version'])
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
  def test_admin_finished_score_is_in_both_boards_and_season_settlement
    @group.add(@admin);@admin.reload
    fund(@admin,'100')
    SiteSetting.rsc_arcade_rewards_enabled=true
    r=start(actor:@admin);advance(r,actor:@admin,finish:true)
    R::ArcadeRun.find(r[:id]).update!(score:656)
    assert_includes R::Arcade.rank_rows(nil,'2048').map { |row| [row[:user_id],row[:score]] },[@admin.id,656]
    p=R::ArcadePeriod.find(r[:period_id])
    assert_equal [[@admin.id,656]],R::Arcade.ranked(p,'2048')
    travel_to(p.ends_at+1.second) { R::Arcade.settle }
    assert_equal '200',R::Account.wallet(@admin.id).balance
  end
  def test_finish_invalidates_cached_empty_boards_after_commit
    r=start
    row=R::ArcadeRun.find(r[:id]);state=row.state.deep_dup
    state['board']=[2,2]+Array.new(14,0);row.update!(state:state)
    p=R::ArcadePeriod.find(r[:period_id])
    assert_empty R::Arcade.rank_rows(nil,'2048')
    assert_empty R::Arcade.rank_rows(p,'2048')
    result=advance(r,finish:true)
    assert_equal 4,result[:state]['score']
    [nil,p].each { |period| assert_equal [[@alice.id,4]],R::Arcade.rank_rows(period,'2048').map { |entry| [entry[:user_id],entry[:score]] } }
    cached=R::Arcade.rank_rows(nil,'2048')
    R::ArcadeRun.transaction do
      row.reload.update!(score:999)
      assert_equal cached,Rails.cache.read(R::Arcade.rank_cache_key(nil,'2048'))
      raise ActiveRecord::Rollback
    end
    assert_equal cached,R::Arcade.rank_rows(nil,'2048')
  end
  def test_grid_batch_replay_and_untrusted_scores
    r=start
    events=%w[l d r u].each_with_index.map { |key,i| [i,key] }
    row=R::ArcadeRun.find(r[:id]);expected=R::Arcade.engine('advance',row.state,4,events)
    result=advance(r,frames:4,events:events)
    assert_equal expected['board'],result[:state]['board']
    assert_equal expected['score'],result[:state]['score']
    assert_equal 20,result[:state]['q'].length
    assert_raises(R::Error) { advance(result,frames:17,events:[]) }
    assert_raises(R::Error) { advance(result,frames:1,events:[[0,'l'],[0,'r']]) }
    assert_raises(R::Error) { advance(result,frames:1,events:[[0,'x:9999']]) }
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
    (%w[fixtures.json fixtures-v2.json fixtures-v3.json fixtures-v4.json].flat_map { |name| JSON.parse(File.read("/rsc/test/arcade/#{name}")) }).each do |f|
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
  def test_expanded_prizes_pay_twenty_places_once
    SiteSetting.rsc_arcade_rewards_enabled=true
    p=R::Arcade.period
    assert_equal [100,60,40,25,15],p.prizes.first(5)
    assert_equal 316,p.prizes.sum
    state=R::Arcade.engine('create','2048',Array.new(24,333),4)
    users=21.times.map do |i|
      user=make_user("rsc_prize_#{i}")
      R::Account.wallet(user.id)
      R::ArcadeRun.create!(user_id:user.id,period_id:p.id,game:'2048',start_key:SecureRandom.uuid,
        state:state,inputs:[],status:'finished',score:2100-i*100,finished_at:Time.current,expires_at:1.hour.from_now)
      user
    end
    travel_to(p.ends_at+1.second) do
      2.times { R::Arcade.settle }
      users.each_with_index { |user,i| assert_equal (p.prizes[i]||0).to_s,R::Account.wallet(user.id).balance }
      assert_equal 1,R::Journal.where(operation:'arcade_prize').count
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

  def test_trial_scores_join_current_ranking_and_current_season_uses_new_rules
    p=R::Arcade.period;p.update!(results:{})
    old_state=R::Arcade.engine('create','2048',Array.new(24,333),1)
    old=R::ArcadeRun.create!(user_id:@bob.id,period_id:p.id,game:'2048',start_key:SecureRandom.uuid,
      state:old_state,inputs:[],status:'finished',score:600,finished_at:Time.current,expires_at:1.hour.from_now)
    modern=start;assert_equal 2,modern[:rules_version];assert_equal p.id,modern[:season_id]
    assert_nil modern[:state]['limit'];assert_equal 4,R::Arcade.season_view(p)[:rules_version]
    assert_raises(R::Error) { R::Arcade.start(actor:@alice,game:'2048',request_id:SecureRandom.uuid) }
    assert_raises(R::Error) { R::Arcade.advance(actor:@alice,id:modern[:id],version:modern[:version],request_id:SecureRandom.uuid,frames:1,events:[]) }
    advance(modern,finish:true);R::ArcadeRun.find(modern[:id]).update!(score:900)
    expected=[[@alice.id,900],[@bob.id,600]]
    assert_equal expected,R::Arcade.ranked(p,'2048')
    assert_equal expected,R::Arcade.ranked(nil,'2048')
  end
  def test_resume_upgrades_trial_save_without_losing_progress
    p=R::Arcade.period
    state=R::Arcade.engine('create','bricks',Array.new(20,333),1)
    state['score']=100;state['board'][0]=0
    row=R::ArcadeRun.create!(user_id:@alice.id,period_id:p.id,game:'bricks',start_key:SecureRandom.uuid,
      state:state,inputs:[],score:100,expires_at:1.hour.from_now)
    resumed=start('bricks');assert_equal row.id,resumed[:id]
    assert_equal 2,resumed[:rules_version];assert_equal 1,resumed[:version]
    assert_equal 100,resumed[:state]['score'];assert_equal 0,resumed[:state]['board'][0]
    assert_equal 1,resumed[:state]['wave'];assert_nil resumed[:state]['limit']
    assert row.reload.inputs.first['checkpoint']
    assert_raises(R::Error) { advance(resumed,version:0,events:[]) }
    assert_equal 100,advance(resumed,events:[])[:state]['score']
  end
  def test_checkpoint_tail_is_bounded_and_resume_renews_retention
    r=start('2048')
    70.times { r=advance(r,events:[]) }
    row=R::ArcadeRun.find(r[:id]);assert_operator row.inputs.length,:<=,65
    assert row.inputs.first['checkpoint'];assert row.inputs.first['digest']
    replay=row.inputs.first['checkpoint'].deep_dup
    row.inputs.drop(1).each do |b|
      replay=R::Arcade.engine('advance',replay,b['frames'],b['events']);replay['q'].concat(b['refill'])
    end
    assert_equal row.state,replay
    before=row.expires_at
    travel_to(3.hours.from_now) do
      resumed=start;assert_equal row.id,resumed[:id]
      after=advance(resumed,events:[]);assert_operator after[:expires_at],:>,before
    end
  end
  def test_season_deadline_banks_checkpoint_and_rejects_late_score
    SiteSetting.rsc_arcade_rewards_enabled=true
    r=start;p=R::ArcadePeriod.find(r[:period_id]);row=R::ArcadeRun.find(r[:id])
    state=row.state.deep_dup;state['score']=40;state['board']=[2,2]+Array.new(14,0);row.update!(state:state,score:40)
    travel_to(p.ends_at+1.second) do
      result=advance(r,events:[[0,'l']])
      assert_equal 'finished',result[:status];assert_equal 40,result[:state]['score']
      R::Arcade.settle;R::Arcade.settle
      assert_equal '200',R::Account.wallet(@alice.id).balance
      assert_equal 40,p.reload.results['2048'].first['score']
      assert_equal 4,R::Arcade.period_rules(p)
    end
  end
  def test_unfinished_new_season_save_is_settled_without_client_return
    SiteSetting.rsc_arcade_rewards_enabled=true
    r=start;p=R::ArcadePeriod.find(r[:period_id]);row=R::ArcadeRun.find(r[:id])
    state=row.state.deep_dup;state['score']=77;row.update!(state:state,score:77)
    travel_to(p.ends_at+1.second) { R::Arcade.settle }
    assert_equal 'finished',row.reload.status
    late=advance(r,events:[[0,'r']]);assert_equal 'finished',late[:status];assert_equal 77,late[:state]['score']
    assert_equal '200',R::Account.wallet(@alice.id).balance
  end
  def test_large_score_storage
    r=start;row=R::ArcadeRun.find(r[:id]);row.update!(score:3_000_000_000)
    assert_equal 3_000_000_000,row.reload.score
  end

end
