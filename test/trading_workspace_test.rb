# frozen_string_literal: true
require "/rsc/test/migration_features_test"
class TradingWorkspaceTest < MigrationFeaturesTest
  def test_workspace_high_risk_status_tracks_own_pending_positions_and_cooldown
    fund
    stock=instrument
    stock.update!(category: 'crypto')
    SiteSetting.rsc_high_risk_enabled=true
    before=[R::Account.count,R::Journal.count,R::Entry.count]
    empty=R::Risk.high_risk_status(@bob.id)
    assert_empty empty[:positions]
    assert_empty empty[:pending]
    assert_nil empty[:cooldown_until]
    assert_equal before,[R::Account.count,R::Journal.count,R::Entry.count]
    result=R::Exchange.submit(actor:@alice,instrument_id:stock.id,side:'long',quantity:'1',leverage:100,high_risk:true,request_id:SecureRandom.uuid)
    pending=R::Risk.high_risk_status(@alice.id)
    assert_equal [stock.id],pending[:pending].map { |p| p[:instrument_id] }
    assert_empty R::Risk.high_risk_status(@bob.id)[:pending]
    fill(stock,R::Order.find(result['order_id']))
    status=R::Risk.high_risk_status(@alice.id)
    assert_empty status[:pending]
    assert_equal [stock.id],status[:positions].map { |p| p[:instrument_id] }
    assert status[:positions].first[:hold_until]
    result=R::Exchange.submit(actor:@alice,instrument_id:stock.id,side:'close',quantity:'1',leverage:100,request_id:SecureRandom.uuid)
    fill(stock,R::Order.find(result['order_id']))
    until_at=R::Order.find(result['order_id']).updated_at+30.minutes
    assert_in_delta until_at.to_f,R::Risk.high_risk_status(@alice.id)[:cooldown_until].to_f,0.01
    assert_equal 'high_risk_cooldown',assert_raises(R::Error) { R::Risk.check!(@alice.id,stock,100,R::Amount.parse('1')) }.code
    R::Order.find(result['order_id']).update_columns(updated_at:31.minutes.ago)
    assert_nil R::Risk.high_risk_status(@alice.id)[:cooldown_until]
    R::Risk.check!(@alice.id,stock,100,R::Amount.parse('1'))
  end

  def test_workspace_stock_session_stats_use_same_response_and_convert_all_fields
    stock=instrument
    stock.update!(provider:'yahoo',provider_symbol:'DEMO')
    now=Time.utc(2026,9,22,15)
    data={'chart'=>{'result'=>[{'meta'=>{'currency'=>'USD','regularMarketPrice'=>'102','previousClose'=>'99','regularMarketTime'=>now.to_i,'exchangeTimezoneName'=>'America/New_York'},
      'timestamp'=>[(now-1.day).to_i,(now-1.hour).to_i,now.to_i],
      'indicators'=>{'quote'=>[{'open'=>[1,100,101],'high'=>[999,102,103],'low'=>[1,98,99]}]}}]}}
    with_provider(data) do
      q=R::MarketData.fetch_quote(stock)
      assert_equal '100.0',q['open'];assert_equal '103.0',q['high'];assert_equal '98.0',q['low'];assert_equal '99.0',q['previous_close']
      assert_equal 'previous_close',q['change_basis']
    end
    assert_nil R::MarketData.optional_price('NaN')
    assert_nil R::MarketData.optional_price('-1')
    assert_equal '12.5',R::MarketData.optional_price('100',BigDecimal('0.125'))
  end

  def test_workspace_crypto_stats_and_stream_describe_24_hours_not_previous_close
    stock=instrument;stock.update!(category:'crypto',provider:'coinbase',provider_symbol:'BTC-USD')
    with_provider(->(_host,path,*) { path.end_with?('/stats') ? {'open'=>'98','high'=>'105','low'=>'90'} : {'price'=>'100','bid'=>'99','ask'=>'101','time'=>Time.current.iso8601} }) do
      q=R::MarketData.fetch_quote(stock)
      assert_equal '24h',q['change_basis'];assert_equal '105.0',q['high'];assert_equal '90.0',q['low']
    end
    q=R::CryptoStream.quote({'type'=>'ticker','product_id'=>'BTC-USD','price'=>'100','time'=>Time.current.iso8601,'open_24h'=>'98','high_24h'=>'106','low_24h'=>'89'})
    assert_equal '24h',q['change_basis'];assert_equal '106.0',q['high'];assert_equal '89.0',q['low']
    stock.update!(provider:'kraken',provider_symbol:'XBTUSD')
    with_provider(->(_host,path,*) { path.end_with?('/Trades') ? {'result'=>{'XBTUSD'=>[['100','1',Time.current.to_f]],'last'=>'1'}} : {'error'=>[],'result'=>{'XBTUSD'=>{'c'=>['100'],'b'=>['99'],'a'=>['101'],'o'=>'98','h'=>['104','105'],'l'=>['92','90']}}} }) do
      q=R::MarketData.fetch_quote(stock)
      assert_equal 'utc_open',q['change_basis'];assert_equal '105.0',q['high'];assert_equal '90.0',q['low']
    end
  end
end
