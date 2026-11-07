# frozen_string_literal: true
require '/rsc/test/business_test'
class GamesTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |n| undef_method n }
  def setup
    super
    R::GameRound.delete_all
    SiteSetting.rsc_games_enabled=true
    SiteSetting.rsc_games_max_stake=500
    fund(@alice,'2000'); fund(@bob,'100')
  end
  def play(game='coin',**args)
    R::Games.start(**{actor:@alice,game:game,stake:'10',choice:'heads',bets:nil,request_id:SecureRandom.uuid}.merge(args))
  end
  def move(round,action,**args)
    R::Games.act(**{actor:@alice,id:round[:id],move:action,version:round[:version],request_id:SecureRandom.uuid}.merge(args))
  end
  def stub_method(object, name, value)
    original=object.method(name)
    object.define_singleton_method(name) { |*args| value.respond_to?(:call) ? value.call(*args) : value }
    yield
  ensure
    object.define_singleton_method(name, original)
  end
  def deck(cards,&block)
    stub_method(R::Games,:shuffle,->(_){cards.reverse},&block)
  end
  def consistent
    R::Account.find_each do |a|
      assert_equal a.balance_units.to_i,R::Entry.where(account_id:a.id).sum(:units).to_i,a.key
      assert_operator a.balance_units.to_i,:>=,0 unless a.kind=='system'
    end
    R::Journal.find_each { |j| assert_equal 0,R::Entry.where(journal_id:j.id).sum(:units).to_i }
  end
  def test_games_record_lookup_is_owner_only_and_independent_of_history_page
    r=play
    21.times { play }
    state=R::Games.state(@alice,round_id:r[:id])
    assert_equal r[:id],state[:selected_round][:id]
    refute_includes state[:history].map { |row| row[:id] },r[:id]
    assert_equal r[:stake],state[:selected_round][:stake]
    assert_equal r[:payout],state[:selected_round][:payout]
    assert_raises(Discourse::NotFound) { R::Games.state(@bob,round_id:r[:id]) }
    assert_raises(Discourse::NotFound) { R::Games.state(@alice,round_id:-1) }
    assert_nil R::Games.state(@alice)[:selected_round]
    assert_equal "/rsc/games?round_id=#{r[:id]}",R::WalletHistory.context({'game_round_id'=>r[:id]},@alice)[:path]
    consistent
  end
  def test_games_record_lookup_hides_active_blackjack_deck_and_hole_card
    r=deck([9,7,5,9,1]) { play('blackjack',choice:nil) }
    state=R::Games.state(@alice,round_id:r[:id])[:selected_round][:state]
    refute state.key?('deck')
    assert_nil state['dealer'][1]
  end
  def test_games_coin_replay_and_conflicting_input
    key=SecureRandom.uuid
    result=stub_method(SecureRandom,:random_number,0) { play(request_id:key) }
    assert_equal '9.6',result[:net]
    assert_equal '2009.6',result[:balance]
    repeat=play(request_id:key)
    assert_equal result[:id],repeat[:id]
    assert repeat[:replayed]
    assert_equal 1,R::GameRound.count
    assert_equal 'idempotency_conflict',assert_raises(R::Error) { play(stake:'20',request_id:key) }.code
    consistent
  end
  def test_games_every_instant_game_settles_once
    %w[slots scratch dice roulette].each do |name|
      r=play(name,choice:name=='dice' ? 'small' : nil,bets:name=='roulette' ? [{'choice'=>'red','stake'=>'10'}] : nil)
      assert_equal 'settled',r[:status]
      assert_equal 0,R::Account.find_by!(key:"game:#{r[:id]}").balance_units.to_i
      refute r[:state].key?('deck')
    end
    consistent
  end
  def test_games_bet_validation_and_insufficient_balance_have_no_effects
    initial=R::Journal.count
    ['0','-1','NaN','501','1.001','1e3'].each { |n| assert_raises(R::Error) { play(stake:n) } }
    assert_raises(R::Error) { play(choice:'edge') }
    assert_raises(R::Error) { play('roulette',bets:[{'choice'=>'n37','stake'=>'10'}]) }
    assert_raises(R::Error) { play('roulette',bets:[{'choice'=>'red','stake'=>'10'},{'choice'=>'red','stake'=>'20'}]) }
    assert_raises(R::Error) { play('roulette',bets:[{'choice'=>'red','stake'=>'300'},{'choice'=>'black','stake'=>'300'}]) }
    assert_equal 'insufficient_balance',assert_raises(R::Error) { play(actor:@bob,stake:'101') }.code
    assert_equal initial,R::Journal.count
    assert_equal 0,R::GameRound.count
  end
  def test_games_disabled_frozen_read_only_and_membership
    SiteSetting.rsc_games_enabled=false;assert_raises(R::Error) { play }
    SiteSetting.rsc_games_enabled=true;SiteSetting.rsc_read_only=true;assert_raises(R::Error) { play }
    SiteSetting.rsc_read_only=false;R::Account.wallet(@alice.id).update!(status:'frozen');assert_raises(R::Error) { play }
    assert_raises(R::Error) { play(actor:@admin) }
    assert_equal 0,R::GameRound.count
  end
  def test_games_blackjack_hidden_cards_persistence_and_ownership
    r=deck([9,7,5,9,1]) { play('blackjack',choice:nil) }
    assert_equal 'playing',r[:status]
    assert_equal [5,nil],r[:state]['dealer']
    refute r[:state].key?('deck')
    assert_equal r[:id],R::Games.state(@alice)[:active][:id]
    assert_raises(ActiveRecord::RecordNotFound) { move(r,'stand',actor:@bob) }
    assert_equal 'game_resume',assert_raises(R::Error) { play('blackjack') }.code
    # Instant games cannot replace or consume the hidden hand.
    play
    assert_equal r[:id],R::Games.state(@alice)[:active][:id]
    result=move(r,'stand')
    assert_equal 'settled',result[:status]
    assert_equal [5,9,1],result[:state]['dealer']
    assert_equal 'push',result[:state]['result']
    consistent
  end
  def test_games_blackjack_natural_and_dealer_natural
    r=deck([0,9,7,8]) { play('blackjack') }
    assert_equal '25',r[:payout]
    assert_equal 'blackjack',r[:state]['result']
    r=deck([0,9,0,11]) { play('blackjack') }
    assert_equal '10',r[:payout]
    r=deck([8,9,0,11]) { play('blackjack') }
    assert_equal '0',r[:payout]
    consistent
  end
  def test_games_blackjack_version_and_replay
    r=deck([1,2,7,8,1,9]) { play('blackjack') }
    key=SecureRandom.uuid
    hit=move(r,'hit',request_id:key)
    assert_equal 3,hit[:state]['player'].size
    assert_equal 'game_changed',assert_raises(R::Error) { move(r,'hit') }.code
    assert_equal hit[:state],move(r,'hit',request_id:key)[:state]
    assert_equal 'game_invalid_action',assert_raises(R::Error) { move(hit,'double') }.code
    result=move(hit,'stand')
    assert_equal 'game_finished',assert_raises(R::Error) { move(result,'hit') }.code
    consistent
  end
  def test_games_blackjack_double_and_atomic_insufficient_funds
    r=deck([4,5,8,7,9]) { play('blackjack',stake:'100',actor:@bob) }
    before=R::GameRound.find(r[:id]).attributes
    assert_equal 'insufficient_balance',assert_raises(R::Error) { move(r,'double',actor:@bob) }.code
    assert_equal before,R::GameRound.find(r[:id]).reload.attributes
    fund(@bob,'100')
    result=move(r,'double',actor:@bob)
    assert_equal '200',result[:stake]
    assert_equal '400',result[:payout]
    assert_equal 3,result[:state]['player'].size
    consistent
  end
  def test_games_score_soft_aces_and_bust
    assert_equal 12,R::Games.score([0,13])
    assert_equal 21,R::Games.score([0,13,8])
    assert_equal 17,R::Games.score([0,5])
    r=deck([9,8,7,8,4]) { play('blackjack') }
    assert_equal 'bust',move(r,'hit')[:state]['result']
    consistent
  end
  def test_games_roulette_expected_return_for_every_bet
    R::Games::ROULETTE_CHOICES.each do |choice|
      assert_equal 36,(0..36).sum { |n| R::Games.roulette_multiplier(choice,n) },choice
    end
    r=stub_method(SecureRandom,:random_number,0) { play('roulette',bets:[{'choice'=>'n0','stake'=>'10'},{'choice'=>'red','stake'=>'10'}]) }
    assert_equal '20',r[:stake];assert_equal '360',r[:payout]
    consistent
  end
  def test_games_slots_expected_return
    total=(0...6).to_a.repeated_permutation(3).sum do |a,b,c|
      draws=[a,b,c]
      round=R::GameRound.new(game:"slots",stake_units:1,state:{})
      stub_method(SecureRandom,:random_number,->(_){draws.shift}) { R::Games.instant(round) }
    end
    assert_equal 211,total
    assert_operator total,:<,216
    assert_equal 10000,R::Games::SCRATCH.sum(&:last)
    assert_equal 9600,R::Games::SCRATCH.sum { |m,w|m*w }
    %w[small big].each do |choice|
      wins=(1..6).to_a.repeated_permutation(3).count { |ds| 
        draws=ds.map { |n|n-1 };round=R::GameRound.new(game:"dice",stake_units:1,state:{"choice"=>choice})
        stub_method(SecureRandom,:random_number,->(_){draws.shift}) { R::Games.instant(round)==2 }
       }
      assert_equal 105,wins
    end
  end
  def test_games_scratch_ten_independent_spots_at_every_prize_boundary
    cursor=0
    R::Games::SCRATCH.each do |multiplier,weight|
      [cursor,cursor+weight-1].each do |draw|
        round=R::GameRound.new(game:'scratch',stake_units:1000,state:{})
        calls=0
        payout=stub_method(SecureRandom,:random_number,->(bound){ assert_equal 10000,bound;calls+=1;draw }) { R::Games.instant(round) }
        assert_equal 10,calls
        assert_equal multiplier*1000,payout
        assert_equal 10,round.state['spots'].length
        assert_equal [multiplier],round.state['spots'].map { |spot| spot['multiplier'] }.uniq
        assert_equal payout,round.state['spots'].sum { |spot| R::Amount.parse(spot['payout']) }
      end
      cursor+=weight
    end
  end
  def test_games_scratch_card_total_price_scaling_and_one_debit
    [10,20].each do |price|
      draws=[0,5699,5700,7599,7600,9399,9400,9899,9900,9999]
      key=SecureRandom.uuid
      r=stub_method(SecureRandom,:random_number,->(_){draws.shift}) { play('scratch',stake:price.to_s,request_id:key) }
      assert_equal price.to_s,r[:stake]
      assert_equal (price/10).to_s,r[:state]['spot_stake']
      assert_equal [0,0,1,1,2,2,5,5,10,250],r[:state]['spots'].map { |spot|spot['multiplier'] }
      assert_equal (276*price/10).to_s,r[:payout]
      assert_equal 2,r[:state]['rules_version']
      assert_equal 1,R::Journal.where(operation:'game_stake',metadata:{game_round_id:r[:id],game:'scratch',reason:'刮刮乐'}).count
      repeat=play('scratch',stake:price.to_s,request_id:key)
      assert repeat[:replayed]
      assert_equal r[:state],repeat[:state]
      consistent
    end
  end
  def test_games_scratch_fractional_card_price_preserves_exact_money
    r=stub_method(SecureRandom,:random_number,5700) { play('scratch',stake:'1.01') }
    assert_equal '0.101',r[:state]['spot_stake']
    assert_equal '1.01',r[:payout]
    assert_equal '0',r[:net]
    consistent
  end
  def test_games_scratch_legacy_history_keeps_original_result
    round=R::GameRound.create!(user_id:@alice.id,game:'scratch',status:'settled',stake_units:R::Amount.parse('10'),payout_units:R::Amount.parse('20'),state:{'tiles'=>[2,2,2,1,1,5,5,10,10],'multiplier'=>2,'rules_version'=>1})
    view=R::Games.view(round)
    assert_equal 9,view[:state]['tiles'].length
    refute view[:state].key?('spots')
    assert_equal '20',view[:payout]
  end
  def test_games_rollback_if_settlement_fails
    n=R::Journal.count
    stub_method(R::Games,:settle,->(*){raise 'simulated failure'}) { assert_raises(RuntimeError) { play } }
    assert_equal 0,R::GameRound.count
    assert_equal n,R::Journal.count
    assert_equal '2000',R::Account.wallet(@alice.id).balance
  end
  def test_games_concurrent_same_request_has_one_charge
    key=SecureRandom.uuid
    results=2.times.map { Thread.new { ActiveRecord::Base.connection_pool.with_connection { play(request_id:key) } } }.map(&:value)
    assert_equal 1,results.map { |r|r[:id] }.uniq.size
    assert_equal 1,R::GameRound.count
    assert_equal 1,R::Journal.where(operation:'game_stake').count
    consistent
  end
  def test_games_concurrent_actions_consume_only_one_card
    r=deck([1,2,8,7,1,1,1]) { play('blackjack') }
    results=2.times.map { Thread.new { ActiveRecord::Base.connection_pool.with_connection { begin;move(r,'hit');rescue R::Error=>e;e.code;end } } }.map(&:value)
    assert_equal 1,results.count { |x|x=='game_changed' }
    assert_equal 3,R::GameRound.find(r[:id]).state['player'].size
    consistent
  end
end
