# frozen_string_literal: true
require '/rsc/test/trading_policy_test'
class CryptoImmediateTest < TradingPolicyTest
  TradingPolicyTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def test_immediate_open_close_reuse_current_quote_and_same_request
    travel_to(Time.utc(2026,10,30,12)) do
      fund;item=coin
      item.update!(provider:'coinbase',provider_symbol:'BTC-USD',quote:item.quote.merge('source'=>'coinbase_ws','bid'=>'99.99','ask'=>'100.01'))
      SiteSetting.rsc_market_data_enabled=true
      original=R::MarketData.method(:sync_one)
      R::MarketData.define_singleton_method(:sync_one){|_|raise 'Unexpected network refresh for fresh quote'}
      travel 60.seconds
      args={actor:@alice,instrument_id:item.id,side:'long',quantity:'1',leverage:10,request_id:'instant-crypto-open'}
      result=R::Exchange.submit(**args)
      assert_equal 'filled',result['status']
      order=R::Order.find(result['order_id'])
      assert_equal '100.01',order.details['price']
      assert_equal 'immediate',R::MarketListing.rows([item]).first[:execution_mode]
      assert_equal({'long'=>'100.01','short'=>'99.99'},R::MarketListing.execution_prices(item))
      journal_count=R::Journal.count
      assert R::Exchange.submit(**args)['replayed']
      assert_equal journal_count,R::Journal.count
      closed=submit(item,side:'close')
      assert_equal 'filled',closed.status
      assert_equal '99.99',closed.details['price']
      assert_equal 0,R::Position.count
      assert_equal 0,R::Entry.sum(:units)
    ensure
      R::MarketData.define_singleton_method(:sync_one,original) if original
    end
  end

  def test_random_execution_adjustment_is_sampled_once_and_preview_is_conservative
    fund;item=coin;SiteSetting.rsc_crypto_extra_slippage_enabled=true
    original=SecureRandom.method(:random_number);calls=0
    SecureRandom.define_singleton_method(:random_number){|_|calls+=1;calls.odd? ? 0 : 3}
    preview=R::MarketListing.execution_prices(item)
    assert_equal 0,calls
    assert_equal '100.05',preview['long']
    assert_equal '99.95',preview['short']
    opening=submit(item)
    assert_equal 'filled',opening.status
    assert_equal 1,calls
    assert_equal '100.02',opening.details['price']
    assert_equal 0,R::Entry.sum(:units)
  ensure
    SecureRandom.define_singleton_method(:random_number,original) if original
  end

  def test_legacy_crypto_order_ignores_next_tick_and_old_execute_at_but_checks_price_band
    travel_to(Time.utc(2026,10,30,12)) do
      fund;item=coin
      travel 30.seconds
      order=legacy_pending_order(item,leverage:10)
      order.update!(execute_at:5.minutes.from_now)
      R::Exchange.process(item.id)
      assert_equal 'filled',order.reload.status
      assert_equal '100',order.details['price']
      assert_equal 0,R::Account.internal("order:#{order.id}").balance_units.to_i
      pending=legacy_pending_order(item,leverage:10)
      item.update!(quote:quote('106').merge('bid'=>'106','ask'=>'106'))
      R::Exchange.process(item.id)
      assert_equal 'rejected',pending.reload.status
      assert_equal 'price_moved',pending.details['error']
      assert_equal 0,R::Entry.sum(:units)
    end
  end
  def test_current_reservation_remains_in_equity_until_fill
    fund;SiteSetting.rsc_high_risk_enabled=true;item=coin
    opening=submit(item,quantity:'250',leverage:100)
    assert_equal 'filled',opening.status
    assert_equal '250',opening.details['margin']
    assert_equal 0,opening.reserved_units.to_i
    assert_equal 0,R::Account.internal("order:#{opening.id}").balance_units.to_i
    assert_equal '0',R::Risk.high_risk_status(@alice.id)[:budget][:available_margin]
    assert_equal 0,R::Entry.sum(:units)
  end

end
