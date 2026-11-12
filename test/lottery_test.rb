# frozen_string_literal: true
require '/rsc/test/business_test'
require 'active_support/testing/time_helpers'
class LotteryTest < NativeBusinessTest
  include ActiveSupport::Testing::TimeHelpers
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |n| undef_method n }
  def setup
    super
    R::LotteryPlan.delete_all
    R::LotteryTicket.delete_all
    R::LotteryDraw.delete_all
    SiteSetting.rsc_games_enabled = true
    SiteSetting.rsc_lottery_enabled = true
    @group.add(@admin)
    fund(@alice, '2000'); fund(@bob, '2000')
    R::Lottery.tick
    @draw = R::LotteryDraw.find_by!(settled_at: nil)
  end
  def teardown
    @bob&.update!(suspended_till:nil)
    travel_back
    SiteSetting.rsc_lottery_enabled = false
    super
  end
  def buy(number = '1234', **args)
    R::Lottery.buy(**{ actor: @alice, draw_id: @draw.id, number: number, quantity: 1, request_id: SecureRandom.uuid }.merge(args))
  end
  def settle(number = 1234)
    @draw.update!(draw_at: 1.second.ago)
    old = SecureRandom.method(:random_number)
    SecureRandom.define_singleton_method(:random_number) { |n| raise 'wrong sample space' unless n == 10_000; number }
    R::Lottery.tick
    @draw.reload
  ensure
    SecureRandom.define_singleton_method(:random_number, old) if old
  end
  def pool
    R::Account.find_by!(key: 'lottery:pool')
  end
  def consistent
    R::Account.find_each do |a|
      assert_equal a.balance_units.to_i, R::Entry.where(account_id: a.id).sum(:units).to_i, a.key
      assert_operator a.balance_units.to_i, :>=, 0 unless a.kind == 'system'
    end
    R::Journal.find_each { |j| assert_equal 0, R::Entry.where(journal_id: j.id).sum(:units).to_i }
    assert_equal R::LotteryDraw.sum(:paid_units).to_i, R::LotteryTicket.sum(:payout_units).to_i
  end
  def test_initial_funding_is_once_and_deadline_is_beijing
    3.times { R::Lottery.tick }
    assert_equal '5000', pool.balance
    assert_equal 1, R::Journal.where(operation: 'lottery_seed').count
    assert_equal Time.utc(2026, 11, 7, 12), R::Lottery.next_deadline(Time.utc(2026, 11, 7, 11, 59, 59))
    assert_equal Time.utc(2026, 11, 8, 12), R::Lottery.next_deadline(Time.utc(2026, 11, 7, 12))
    assert_equal 1, R::LotteryDraw.where(settled_at: nil).count
    consistent
  end
  def test_buy_splits_funds_and_preserves_leading_zero
    key = SecureRandom.uuid
    a = buy('0012', quantity: 2, request_id: key)
    b = buy('0012', quantity: 2, request_id: key)
    assert_equal a[:ticket][:id], b[:ticket][:id]
    assert b[:replayed]
    assert_equal '1990', b[:balance]
    assert_equal '5008', pool.balance
    assert_equal '2', R::Account.find_by!(key: 'system:lottery').balance
    assert_equal '0012', a[:ticket][:number]
    assert_equal 'idempotency_conflict', assert_raises(R::Error) { buy('0013', quantity: 2, request_id: key) }.code
    consistent
  end
  def test_invalid_requests_and_insufficient_balance_leave_no_ticket
    count = R::Journal.count
    ['123','12345','1e03','-001','１２３４',1234,{}].each { |n| assert_equal 'lottery_number', assert_raises(R::Error) { buy(n) }.code }
    [0,21,1.5,'1'].each { |q| assert_equal 'lottery_quantity', assert_raises(R::Error) { buy(quantity: q) }.code }
    stranger = make_user('lottery_stranger'); @group.add(stranger)
    assert_equal 'insufficient_balance', assert_raises(R::Error) { buy(actor: stranger) }.code
    assert_equal 0, R::LotteryTicket.count
    assert_equal count, R::Journal.count
    consistent
  end
  def test_limit_covers_all_numbers_and_concurrent_requests
    buy('0000', quantity: 18)
    results = Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          buy('9999', quantity: 2)
          :ok
        rescue R::Error => e
          e.code
        end
      end
    end.map(&:value)
    assert_equal 1, results.count(:ok)
    assert_equal 3, results.count('lottery_limit')
    assert_equal 20, R::LotteryTicket.where(user_id: @alice.id, draw_id: @draw.id).sum(:quantity)
    assert_equal '1900', R::Account.wallet(@alice.id).balance
    consistent
  end
  def test_concurrent_same_request_buys_once
    key = SecureRandom.uuid
    results = Array.new(4) { Thread.new { ActiveRecord::Base.connection_pool.with_connection { buy(request_id: key) } } }.map(&:value)
    assert_equal 1, results.map { |r| r[:ticket][:id] }.uniq.size
    assert_equal 3, results.count { |r| r[:replayed] }
    assert_equal 1, R::LotteryTicket.count
    consistent
  end
  def test_small_prizes_then_shared_jackpot_and_one_restart_seed
    a = buy('1299')[:ticket][:id] # two exact positions
    b = buy('1239')[:ticket][:id] # three exact positions
    c = buy('1234', quantity: 2)[:ticket][:id]
    d = buy('1234', actor: @bob)[:ticket][:id]
    buy('4321') # same digits in wrong places: not a winner
    draw = settle
    assert_equal '10', R::Amount.format(R::LotteryTicket.find(a).payout_units)
    assert_equal '100', R::Amount.format(R::LotteryTicket.find(b).payout_units)
    per = (5024 - 110) * R::Amount::UNIT / 3
    assert_equal per * 2, R::LotteryTicket.find(c).payout_units.to_i
    assert_equal per, R::LotteryTicket.find(d).payout_units.to_i
    assert_equal 3, draw.winning_tickets
    assert_equal 110 * R::Amount::UNIT, draw.small_paid_units.to_i
    assert_equal 3000 * R::Amount::UNIT + ((5024 - 110) * R::Amount::UNIT % 3), pool.balance_units.to_i
    3.times { R::Lottery.tick }
    assert_equal 2, R::Journal.where(operation: 'lottery_seed').count
    assert_equal 1, R::Journal.where(operation: 'lottery_prize').count
    a = R::Lottery.accounting
    assert_equal '30', a[:revenue]
    assert_equal '6', a[:fees]
    assert_equal '8000', a[:subsidies]
    assert_equal '-7994', a[:net_recovered]
    assert_equal '110', a[:small_prizes]
    entry = R::Entry.joins(:journal).where(account_id: R::Account.wallet(@alice.id).id, discourse_rsc_journals: { operation: 'lottery_prize' }).first!
    assert_nil R::WalletHistory.native_entry(entry, @alice)[:counterparty]
    consistent
  end
  def test_no_jackpot_rolls_pool_without_subsidy
    buy('1299', quantity: 2)
    settle
    assert_equal '4988', pool.balance
    assert_equal 1, R::Journal.where(operation: 'lottery_seed').count
    assert_equal 0, @draw.winning_tickets
    consistent
  end
  def test_short_pool_proportional_prizes_and_purchase_splitting_cannot_gain
    buy('1239', quantity: 2)
    buy('1239', actor: @bob)
    buy('1239', actor: @bob)
    # Simulate a legitimately depleted pool, keeping the accounting balanced.
    R::Ledger.post(operation: 'test_deplete', actor_user_id: 0, request_id: SecureRandom.uuid,
      postings: { pool.id => -(pool.balance_units.to_i - 31 * R::Amount::UNIT), R::Account.issuance.id => pool.balance_units.to_i - 31 * R::Amount::UNIT })
    settle
    totals = R::LotteryTicket.group(:user_id).sum(:payout_units)
    assert_equal totals[@alice.id], totals[@bob.id]
    assert_equal '15.5', R::Amount.format(totals[@alice.id])
    assert_equal '0', pool.balance
    assert_equal 1, R::Journal.where(operation: 'lottery_seed').count
    consistent
  end
  def test_deadline_and_downtime_do_not_allow_late_purchase_or_repeat_draw
    buy('1234')
    old = @draw.id
    travel_to(@draw.draw_at + 3.days) do
      assert_equal 'lottery_closed', assert_raises(R::Error) { buy }.code
      assert R::LotteryDraw.find(old).settled_at
      assert_equal 2, R::LotteryDraw.count
      fresh = R::LotteryDraw.find_by!(settled_at: nil)
      assert_operator fresh.draw_at, :>, Time.current
      3.times { R::Lottery.tick }
      assert_equal 2, R::LotteryDraw.count
    end
    consistent
  end
  def test_replay_after_draw_and_frozen_wallet_receives_prize
    key = SecureRandom.uuid
    first = buy('1234', request_id: key)
    R::Account.wallet(@alice.id).update!(status: 'frozen')
    settle
    assert_operator R::Account.wallet(@alice.id).balance_units.to_i, :>, 2000 * R::Amount::UNIT
    assert_equal 'wallet_frozen', assert_raises(R::Error) { buy }.code
    R::Account.wallet(@alice.id).update!(status: 'active')
    replay = buy('1234', request_id: key)
    assert replay[:replayed]
    assert_equal first[:ticket][:id], replay[:ticket][:id]
    assert_equal 1, R::LotteryTicket.count
    consistent
  end
  def test_no_other_players_numbers_or_admin_accounting_exposed
    buy('9999', actor: @bob)
    state = R::Lottery.state(@alice)
    assert_empty state[:mine]
    assert_nil state[:accounting]
    assert_nil state[:current][:number]
    refute JSON.generate(state).include?('9999')
    assert_equal '5000', R::Lottery.state(@admin)[:accounting][:subsidies]
    SiteSetting.rsc_read_only = true
    assert_equal true, R::Lottery.state(@alice)[:read_only]
    assert_raises(R::Error) { buy }
    SiteSetting.rsc_read_only = false
    SiteSetting.rsc_lottery_enabled = false
    assert_nil R::Lottery.summary
    assert_equal 'lottery_disabled', assert_raises(R::Error) { buy }.code
    consistent
  end
  def test_failed_restart_rolls_back_payout_result_and_ticket_prizes
    buy('1234')
    balance = R::Account.wallet(@alice.id).balance
    old = R::Ledger.method(:post)
    R::Ledger.define_singleton_method(:post) do |**args|
      raise 'simulated failure' if args[:operation] == 'lottery_seed'
      old.call(**args)
    end
    assert_raises(RuntimeError) { settle }
    assert_nil @draw.reload.settled_at
    assert_nil @draw.number
    assert_equal '5004', pool.balance
    assert_equal balance, R::Account.wallet(@alice.id).balance
    assert_equal 0, R::LotteryTicket.sum(:payout_units)
    assert_equal 0, R::Journal.where(operation: 'lottery_prize').count
    R::Ledger.define_singleton_method(:post, old)
    settle
    assert_equal '3000', pool.balance
    consistent
  ensure
    R::Ledger.define_singleton_method(:post, old) if old
  end

  def test_parallel_draw_workers_settle_and_reseed_once
    buy('0000')
    @draw.update!(draw_at: 1.second.ago)
    old = SecureRandom.method(:random_number)
    SecureRandom.define_singleton_method(:random_number) { |n| 0 }
    Array.new(4) { Thread.new { ActiveRecord::Base.connection_pool.with_connection { R::Lottery.tick } } }.each(&:value)
    assert_equal '0000', @draw.reload.number
    assert_equal 2, R::LotteryDraw.count
    assert_equal 1, R::Journal.where(operation: 'lottery_prize').count
    assert_equal 2, R::Journal.where(operation: 'lottery_seed').count
    assert_equal '3000', pool.balance
    consistent
  ensure
    SecureRandom.define_singleton_method(:random_number, old) if old
  end

  def test_lottery_ranking_uses_net_of_all_tickets_in_draw_and_excludes_unsettled
    @bob.update!(admin:true)
    buy('1234')
    buy('0000',quantity:3)
    buy('1234',actor:@bob)
    assert_empty R::GameRanking.calculate(game:'lottery',period:'all')[:rows]
    settle
    board=R::GameRanking.calculate(game:'lottery',period:'all')
    assert_equal [@bob.id,@alice.id],board[:rows].map { |r| r[:user][:id] }
    [@alice,@bob].each do |user|
      tickets=R::LotteryTicket.where(draw_id:@draw.id,user_id:user.id)
      net=tickets.sum(:payout_units).to_i-tickets.sum(:quantity)*5*R::Amount::UNIT
      row=board[:rows].find { |r| r[:user][:id]==user.id }
      assert_equal R::Amount.format(net),row[:value]
    end
    assert board[:rows].all? { |r| r.keys.sort==[:achieved_at,:user,:value].sort }
    consistent
  ensure
    @bob.update!(admin:false)
  end

  def save_plan(rows = [{'number'=>'0012','quantity'=>2,'enabled'=>true}], actor:@alice, version:0)
    R::LotteryAutobet.save(actor:actor,selections:rows,version:version)
  end
  def open_next_draw
    travel_to @draw.draw_at + 1.second
    R::Lottery.tick
    @draw = R::LotteryDraw.find_by!(settled_at:nil)
  end
  def test_auto_plan_next_draw_multiple_numbers_and_idempotency
    save_plan([{'number'=>'0012','quantity'=>2,'enabled'=>true},{'number'=>'3456','quantity'=>3,'enabled'=>true},{'number'=>'9999','quantity'=>1,'enabled'=>false}])
    R::LotteryAutobet.process
    assert_equal 0,R::LotteryTicket.count
    open_next_draw
    threads=3.times.map { Thread.new { ActiveRecord::Base.connection_pool.with_connection { R::LotteryAutobet.process } } };threads.each(&:value)
    assert_equal [['0012',2],['3456',3]],R::LotteryTicket.order(:id).pluck(:number,:quantity)
    assert_equal '1975',R::Account.wallet(@alice.id).balance
    result=R::LotteryAutobet.view(@alice)[:last_result]
    assert_equal @draw.id,result['draw_id']
    assert result['rows'].all? { |r| r['status']=='bought' }
    R::LotteryAutobet.process
    assert_equal 2,R::LotteryTicket.count
    consistent
  end
  def test_auto_plan_validation_and_concurrent_editor_version
    save_plan
    assert_equal 'lottery_plan_changed',assert_raises(R::Error) { save_plan }.code
    assert_equal 'lottery_plan_duplicate',assert_raises(R::Error) { save_plan([{'number'=>'0000','quantity'=>1,'enabled'=>true}]*2,version:1) }.code
    assert_equal 'lottery_plan_limit',assert_raises(R::Error) { save_plan([{'number'=>'0000','quantity'=>20,'enabled'=>true},{'number'=>'0001','quantity'=>1,'enabled'=>true}],version:1) }.code
    [[],nil,'1',1.5].each { |q| assert_raises(R::Error) { save_plan([{'number'=>'0001','quantity'=>q,'enabled'=>true}],version:1) } }
    assert_equal 1,R::LotteryPlan.find_by!(user_id:@alice.id).version
  end
  def test_auto_plan_shares_manual_limit_and_does_not_retry_skips
    save_plan
    open_next_draw
    buy('8888',quantity:19)
    R::LotteryAutobet.process
    assert_equal 19,R::LotteryTicket.sum(:quantity)
    assert_equal 'skipped',R::LotteryAutobet.view(@alice)[:last_result]['rows'][0]['status']
    assert_equal '1905',R::Account.wallet(@alice.id).balance
    2.times { R::LotteryAutobet.process }
    assert_equal 1,R::LotteryTicket.count
    consistent
  end
  def test_auto_plan_insufficient_frozen_and_suspended_accounts
    stranger=make_user('auto_empty');@group.add(stranger)
    save_plan(actor:stranger);save_plan(actor:@alice);save_plan(actor:@bob)
    open_next_draw
    R::Account.wallet(@alice.id).update!(status:'frozen')
    @bob.update!(suspended_till:2.days.from_now)
    R::LotteryAutobet.process
    assert_equal 0,R::LotteryTicket.count
    [stranger,@alice,@bob].each { |u| assert_equal 'skipped',R::LotteryAutobet.view(u)[:last_result]['rows'][0]['status'] }
    fund(stranger,'20')
    R::LotteryAutobet.process
    assert_equal 0,R::LotteryTicket.count
    consistent
  end
  def test_auto_plan_partial_budget_and_pause_keeps_existing_tickets
    stranger=make_user('auto_small');@group.add(stranger);fund(stranger,'5')
    save_plan([{'number'=>'0001','quantity'=>2,'enabled'=>true},{'number'=>'0002','quantity'=>1,'enabled'=>true}],actor:stranger)
    open_next_draw;R::LotteryAutobet.process
    assert_equal ['0002'],R::LotteryTicket.pluck(:number)
    assert_equal %w[skipped bought],R::LotteryAutobet.view(stranger)[:last_result]['rows'].map { |r| r['status'] }
    save_plan([],actor:stranger,version:1)
    assert_equal 1,R::LotteryTicket.count
    open_next_draw;R::LotteryAutobet.process
    assert_equal 1,R::LotteryTicket.count
    consistent
  end
  def test_auto_plan_failure_rolls_back_and_can_retry
    save_plan;open_next_draw
    original=R::Lottery.method(:purchase!)
    R::Lottery.define_singleton_method(:purchase!) { |**args| original.call(**args);raise 'simulated failure' }
    assert_raises(RuntimeError) { R::LotteryAutobet.process }
    assert_equal 0,R::LotteryTicket.count
    assert_nil R::LotteryPlan.find_by!(user_id:@alice.id).last_draw_id
    assert_equal '2000',R::Account.wallet(@alice.id).balance
    R::Lottery.define_singleton_method(:purchase!,original)
    R::LotteryAutobet.process
    assert_equal 1,R::LotteryTicket.count
    consistent
  ensure
    R::Lottery.define_singleton_method(:purchase!,original) if original
  end

end
