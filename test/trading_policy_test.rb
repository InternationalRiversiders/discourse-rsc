# frozen_string_literal: true
require '/rsc/test/migration_features_test'
require 'active_support/testing/time_helpers'

class TradingPolicyTest < MigrationFeaturesTest
  include ActiveSupport::Testing::TimeHelpers

  def coin(symbol = 'COIN')
    item = instrument
    item.update!(symbol: symbol, category: 'crypto', quote: quote('100').merge('bid'=>'100','ask'=>'100'))
    item
  end

  def submit(item, side: 'long', quantity: '1', leverage: 10)
    result = R::Exchange.submit(actor: @alice, instrument_id: item.id, side: side, quantity: quantity, leverage: leverage, high_risk: leverage > 10, request_id: SecureRandom.uuid)
    R::Order.find(result['order_id'])
  end

  def advance_quote(item, price = '100', delay = 0)
    item.update!(quote: quote(price).merge('bid'=>price,'ask'=>price,'source_time'=>(Time.current-delay).iso8601(6),'delay_seconds'=>delay))
    R::Exchange.process(item.id)
  end

  def test_policy_standard_positions_use_balance_without_legacy_percentage_caps
    travel_to(Time.utc(2026,10,7,15)) do
      fund; first=coin('FIRST'); second=coin('SECOND')
      opened=submit(first,quantity:'60')
      travel 1.second
      advance_quote(first)
      assert_equal 'filled',opened.reload.status
      another=submit(second,quantity:'30')
      travel 1.second
      advance_quote(second)
      assert_equal 'filled',another.reload.status
      assert_equal R::Amount.parse('900'),R::Position.sum(:margin_units)
      assert_equal 0,R::Entry.sum(:units)
      assert_operator R::Account.wallet(@alice.id).balance_units,:>=,0
      # Enabling the optional legacy policy restores its old percentage checks.
      SiteSetting.rsc_standard_position_limits_enabled=true
      assert_equal 'position_risk_limit',assert_raises(R::Error) { R::Risk.check!(@alice.id,first,10,R::Amount.parse('1')) }.code
    end
  end

  def test_policy_daily_open_caps_are_optional_and_never_block_closes
    travel_to(Time.utc(2026,10,7,15)) do
      fund; item=coin
      25.times { R::Order.create!(user_id:@alice.id,instrument_id:item.id,side:'long',leverage:1,status:'canceled',quantity_units:R::Amount::UNIT,details:{}) }
      opened=submit(item)
      travel 1.second; advance_quote(item)
      assert_equal 'filled',opened.reload.status
      SiteSetting.rsc_crypto_daily_open_limit=1
      SiteSetting.rsc_crypto_symbol_daily_open_limit=1
      assert_equal 'crypto_daily_limit',assert_raises(R::Error) { submit(item) }.code
      closed=submit(item,side:'close')
      travel 1.second; advance_quote(item)
      assert_equal 'filled',closed.reload.status
      assert_equal 0,R::Position.count
      # Existing close records do not consume a new day's optional opening cap.
      R::Order.where(side:'long').update_all(created_at:1.day.ago)
      assert_equal 'pending',submit(item).status
    end
  end

  def test_policy_crypto_confirms_only_with_new_source_quote_and_can_cancel
    travel_to(Time.utc(2026,10,7,15)) do
      fund; item=coin; opened=submit(item)
      assert_equal opened.created_at,opened.execute_at
      R::Exchange.process(item.id)
      assert_equal 'pending',opened.reload.status
      assert R::Views.order(opened)[:can_cancel]
      R::Exchange.cancel(actor:@alice,order_id:opened.id,request_id:SecureRandom.uuid)
      assert_equal '1000',R::Account.wallet(@alice.id).balance
      another=submit(item)
      travel 1.second; advance_quote(item)
      assert_equal 'filled',another.reload.status
      assert_nil R::Position.first.hold_until
      assert_nil R::Views.position(R::Position.first)[:hold_until]
    end
  end

  def test_policy_existing_normal_locks_are_ignored_without_rewriting_costs
    travel_to(Time.utc(2026,10,7,15)) do
      fund; item=coin; submit(item)
      travel 1.second; advance_quote(item)
      position=R::Position.first
      position.update!(hold_until:5.minutes.from_now)
      before=position.attributes.slice('quantity_units','average_units','margin_units')
      ledger=R::Journal.count
      assert_nil R::Views.position(position)[:hold_until]
      assert_equal before,position.reload.attributes.slice('quantity_units','average_units','margin_units')
      assert_equal ledger,R::Journal.count
      assert_equal 'pending',submit(item,side:'close').status
    end
  end

  def test_policy_high_risk_locks_and_cooldown_follow_current_settings
    travel_to(Time.utc(2026,10,7,15)) do
      fund; SiteSetting.rsc_high_risk_enabled=true; item=coin
      opened=submit(item,leverage:100)
      travel 1.second; advance_quote(item)
      position=R::Position.first;position.update!(hold_until:5.minutes.from_now)
      assert_equal opened.created_at+60.seconds,R::Views.position(position)[:hold_until]
      assert_equal 'position_locked',assert_raises(R::Error) { submit(item,side:'close') }.code
      travel 60.seconds; advance_quote(item)
      closed=submit(item,side:'close')
      travel 1.second; advance_quote(item)
      assert_equal 'filled',closed.reload.status
      assert_equal closed.updated_at+300.seconds,R::Risk.high_risk_cooldown_until(@alice.id)
      assert_equal 'high_risk_cooldown',assert_raises(R::Error) { submit(item,leverage:100) }.code
      travel 301.seconds; advance_quote(item)
      assert_nil R::Risk.high_risk_cooldown_until(@alice.id)
      assert_equal 'pending',submit(item,leverage:100).status
      SiteSetting.rsc_high_risk_hold_seconds=0
      SiteSetting.rsc_high_risk_cooldown_seconds=0
      assert_nil R::Risk.high_risk_cooldown_until(@alice.id)
    end
  end

  def test_policy_high_risk_shared_budget_replaces_symbol_and_weighted_caps
    fund;SiteSetting.rsc_high_risk_enabled=true;first=coin('FIRST');second=coin('SECOND')
    assert_equal 'high_risk_budget',assert_raises(R::Error) { R::Risk.check!(@alice.id,first,100,R::Amount.parse('251')) }.code
    SiteSetting.rsc_high_risk_margin_percent=30
    R::Risk.check!(@alice.id,first,100,R::Amount.parse('251'))
    submit(first,leverage:100)
    assert_equal 'pending',submit(second,leverage:100).status
    budget=R::Risk.high_risk_status(@alice.id)[:budget]
    assert_equal '2',budget[:used_margin]
    assert_equal '298',budget[:available_margin]
    # Ordinary positions remain available even with a high-risk position pending.
    assert_equal 'pending',submit(coin('THIRD'),quantity:'60').status
  end

  def test_policy_delayed_markets_still_wait_for_source_timestamp_after_order
    travel_to(Time.utc(2026,10,7,15)) do
      fund;item=instrument;advance_quote(item,'100',900)
      opened=submit(item,quantity:'50')
      assert_in_delta 870,(opened.execute_at-opened.created_at),0.01
      travel 871.seconds;advance_quote(item,'100',900)
      assert_equal 'pending',opened.reload.status
      travel 30.seconds;advance_quote(item,'100',900)
      assert_equal 'filled',opened.reload.status
      assert_nil R::Views.position(R::Position.first)[:hold_until]
      closed=submit(item,side:'close',quantity:'50')
      assert_operator closed.execute_at,:>,Time.current
    end
  end

  def test_policy_bid_ask_execution_removes_only_extra_random_slippage
    item=coin;item.update!(quote:item.quote.merge('bid'=>'99.99','ask'=>'100.01'))
    5.times do
      assert_equal R::Amount.parse('100.01'),R::Exchange.execution_price(item,'long',R::Amount.parse('100'))
      assert_equal R::Amount.parse('99.99'),R::Exchange.execution_price(item,'short',R::Amount.parse('100'))
    end
    SiteSetting.rsc_crypto_extra_slippage_enabled=true
    assert_operator R::Exchange.execution_price(item,'long',R::Amount.parse('100')),:>,R::Amount.parse('100.01')
    SiteSetting.rsc_crypto_extra_slippage_enabled=false
    item.update!(quote:quote('100'))
    assert_operator R::Exchange.execution_price(item,'long',R::Amount.parse('100')),:>,R::Amount.parse('100')
    refute R::Exchange.reliable_book?({'bid'=>'101','ask'=>'100'})
  end

  def test_policy_high_risk_automatic_liquidation_ignores_manual_hold
    travel_to(Time.utc(2026,10,7,15)) do
      fund;SiteSetting.rsc_high_risk_enabled=true;item=coin
      submit(item,leverage:100)
      travel 1.second;advance_quote(item)
      assert_operator R::Risk.hold_until(R::Position.first),:>,Time.current
      travel 1.second;advance_quote(item,'99')
      assert_equal 0,R::Position.count
      assert_equal 'stock_liquidated',R::Order.where(side:'close').last.details['reason']
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_policy_optional_confirmation_delay_does_not_replace_freshness_check
    travel_to(Time.utc(2026,10,7,15)) do
      fund;item=coin;SiteSetting.rsc_crypto_confirmation_delay_seconds=30
      opened=submit(item)
      travel 1.second;advance_quote(item)
      assert_equal 'pending',opened.reload.status
      travel 30.seconds;advance_quote(item)
      assert_equal 'filled',opened.reload.status
    end
  end

  def test_policy_relaxation_keeps_balance_price_band_and_idempotency_guards
    travel_to(Time.utc(2026,10,7,15)) do
      fund;item=coin
      assert_equal 'insufficient_balance',assert_raises(R::Error) { submit(item,quantity:'1000') }.code
      assert_equal 0,R::Order.count
      opened=submit(item)
      travel 1.second;advance_quote(item,'106')
      assert_equal 'rejected',opened.reload.status
      assert_equal 'price_moved',opened.details['error']
      assert_equal '1000',R::Account.wallet(@alice.id).balance
      args={actor:@alice,instrument_id:item.id,side:'long',quantity:'1',leverage:10,request_id:SecureRandom.uuid}
      first=R::Exchange.submit(**args);balance=R::Account.wallet(@alice.id).balance
      second=R::Exchange.submit(**args)
      assert second['replayed'];assert_equal first['order_id'],second['order_id']
      assert_equal balance,R::Account.wallet(@alice.id).balance
      travel 121.seconds
      R::Exchange.process(item.id)
      assert_equal 'pending',R::Order.find(first['order_id']).status
      assert_equal 0,R::Entry.sum(:units)
    end
  end
end
