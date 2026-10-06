# frozen_string_literal: true
require '/rsc/test/trading_policy_test'

class TradingUxTest < TradingPolicyTest
  def test_ux_pence_precision_accepts_existing_cached_rates
    item=instrument
    item.update!(category:'eu',quote:quote('19.55').merge('fx_rate'=>'0.01328374070138150903'))
    R::HistoryCache.create!(instrument_id:item.id,range:'1mo',source:'provider',currency:'GBp',candles:Array.new(20) { {close:'1471.8',volume:'1000000'} })
    assert_raises(R::Error) { R::Amount.parse(item.quote['fx_rate']) }
    R::TradingRules.opening!(item,R::Amount.parse('27'))
    item.update!(quote:item.quote.except('fx_rate'))
    R::TradingRules.opening!(item,R::Amount.parse('27'))
    assert_equal 0,R::Journal.count
  end

  def test_ux_high_risk_multiple_positions_and_immediate_manual_close
    travel_to(Time.utc(2026,10,7,15)) do
      fund;SiteSetting.rsc_high_risk_enabled=true
      SiteSetting.rsc_high_risk_hold_seconds=0;SiteSetting.rsc_high_risk_cooldown_seconds=0
      first=coin('FIRST');second=coin('SECOND')
      opened=submit(first,leverage:100);travel 1.second;advance_quote(first)
      assert_equal 'filled',opened.reload.status
      assert_equal 'pending',submit(second,leverage:100).status
      assert_nil R::Risk.hold_until(R::Position.first)
      closed=submit(first,side:'close');travel 1.second;advance_quote(first)
      assert_equal 'filled',closed.reload.status
      assert_nil R::Risk.high_risk_cooldown_until(@alice.id)
      assert_equal 'pending',submit(first,leverage:100).status
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_ux_pending_high_risk_orders_share_budget_without_double_counting
    fund;SiteSetting.rsc_high_risk_enabled=true;first=coin('FIRST');second=coin('SECOND')
    order=submit(first,quantity:'200',leverage:100)
    budget=R::Risk.high_risk_status(@alice.id)[:budget]
    assert_equal '1000',budget[:equity]
    assert_equal '200',budget[:used_margin]
    assert_equal '50',budget[:available_margin]
    assert_equal 'high_risk_budget',assert_raises(R::Error) { submit(second,quantity:'51',leverage:100) }.code
    assert_equal 1,R::Order.count
    R::Risk.check!(@alice.id,first,100,R::Amount.parse('200'),excluding_order:order.id)
    R::Exchange.cancel(actor:@alice,order_id:order.id,request_id:SecureRandom.uuid)
    assert_equal '250',R::Risk.high_risk_status(@alice.id)[:budget][:available_margin]
  end

  def test_ux_actual_ask_price_is_checked_against_budget_before_filling
    travel_to(Time.utc(2026,10,7,15)) do
      fund;SiteSetting.rsc_high_risk_enabled=true;item=coin
      order=submit(item,quantity:'250',leverage:100)
      travel 1.second
      item.update!(quote:quote('100').merge('bid'=>'100','ask'=>'100.01'))
      R::Exchange.process(item.id)
      assert_equal 'rejected',order.reload.status
      assert_equal 'high_risk_budget',order.details['error']
      assert_equal '1000',R::Account.wallet(@alice.id).balance
      assert_equal 0,R::Position.count
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_ux_closed_market_precedes_stale_quote_message
    travel_to(Time.utc(2026,10,11,15)) do
      item=instrument
      Discourse.cache.write('rsc:trading-hours',{item.symbol=>'09:30-16:00 America/New_York'})
      item.update!(quote:quote('100').merge('source_time'=>2.days.ago.iso8601,'received_at'=>2.days.ago.iso8601))
      assert_equal 'market_closed',assert_raises(R::Error) { R::Exchange.price!(item,trading:true) }.code
      assert_equal 'quote_stale',assert_raises(R::Error) { R::Exchange.price!(item) }.code
    end
  end

  def test_ux_quiet_coinbase_uses_timestamped_book_not_stale_trade
    travel_to(Time.utc(2026,10,7,15)) do
      item=coin;item.update!(provider:'coinbase',provider_symbol:'SHIB-USD')
      old=5.minutes.ago.iso8601(6)
      ticker={'price'=>'0.0000058','bid'=>'0.0000058','ask'=>'0.00000581','time'=>old}
      calls=[]
      with_provider(->(_host,path,*) {
        calls<<path
        if path.end_with?('/ticker');ticker
        elsif path.end_with?('/stats');{'open'=>'0.0000059'}
        else;{'time'=>Time.current.iso8601(6),'bids'=>[['0.0000058','1000000',1]],'asks'=>[['0.00000581','2000000',1]],'auction_mode'=>false}
        end
      }) { item.update!(quote:R::MarketData.fetch_quote(item)) }
      assert_equal 'order_book_midpoint',item.quote['pricing_method']
      assert_equal '0.000005805',item.quote['price']
      assert_equal old,item.quote['last_trade_at']
      assert_equal R::Amount.parse('0.000005805'),R::Exchange.price!(item,trading:true)
      assert_equal 1,calls.count { |path| path.end_with?('/book') }
    end
  end

  def test_ux_book_fallback_rejects_stale_future_crossed_empty_and_wide_books
    q=quote('100');bid=[['99.9','10']];ask=[['100.1','10']]
    [121.seconds.ago,6.seconds.from_now].each do |at|
      assert_equal 'quote_stale',assert_raises(R::Error) { R::MarketData.book_quote(q,bids:bid,asks:ask,at:at.iso8601(6)) }.code
    end
    [[[],ask],[[['101','10']],ask],[bid,[['110','10']]],[bid,[['100.1','0']]]].each do |b,a|
      assert_raises(R::Error) { R::MarketData.book_quote(q,bids:b,asks:a,at:Time.current.iso8601(6)) }
    end
    refute q.key?('pricing_method')
  end

  def test_ux_quiet_kraken_uses_book_update_time
    item=coin;item.update!(provider:'kraken',provider_symbol:'XMRUSD')
    with_provider(->(_host,path,*) {
      case path
      when '/0/public/Ticker';{'result'=>{'XMRUSD'=>{'c'=>['100'],'o'=>'99','b'=>['99.9'],'a'=>['100.1']}}}
      when '/0/public/Trades';{'result'=>{'XMRUSD'=>[['100','1',5.minutes.ago.to_f]],'last'=>'1'}}
      else;{'result'=>{'XMRUSD'=>{'bids'=>[['99.9','10',Time.current.to_i]],'asks'=>[['100.1','10',Time.current.to_i]]}}}
      end
    }) { item.update!(quote:R::MarketData.fetch_quote(item)) }
    assert_equal '100',item.quote['price']
    assert_equal 'order_book_midpoint',item.quote['pricing_method']
    assert_equal R::Amount.parse('100'),R::Exchange.price!(item,trading:true)
  end
end
