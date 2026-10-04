# frozen_string_literal: true
require '/rsc/test/migration_features_test'
require 'active_support/testing/time_helpers'
class ForexPrecisionTest < MigrationFeaturesTest
  include ActiveSupport::Testing::TimeHelpers

  def forex
    stock=instrument
    stock.update!(symbol:'FX:JPY',category:'forex',asset_type:'forex',provider:'yahoo',provider_symbol:'JPYUSD=X',currency:'USD',minimum_units:R::Amount.parse('0.01'),step_units:R::Amount.parse('0.01'))
    stock
  end

  def chart(rate='160')
    now=Time.current
    {'chart'=>{'result'=>[{'meta'=>{'symbol'=>'JPY=X','currency'=>'JPY','regularMarketPrice'=>rate,'previousClose'=>'162','regularMarketTime'=>now.to_i,'exchangeTimezoneName'=>'UTC','exchangeDataDelayedBy'=>0,'currentTradingPeriod'=>{'regular'=>{'start'=>(now-1.hour).to_i,'end'=>(now+1.hour).to_i}}},
      'timestamp'=>[(now-10.minutes).to_i,now.to_i], 'indicators'=>{'quote'=>[{'open'=>['161','160'],'high'=>['162','161'],'low'=>['160','159'],'close'=>['161',rate],'volume'=>[0,0]}]}}]}}
  end

  def test_forex_quote_reciprocal_preserves_units_and_inverts_extrema
    item=forex
    with_provider(->(_host,path,*) { assert_includes path,'JPY%3DX';chart }) do
      q=R::MarketData.fetch_quote(item)
      assert_equal '0.00625',q['price']
      assert_equal R::MarketData.reciprocal('162'),q['previous_close']
      assert_equal R::MarketData.reciprocal('161'),q['open']
      assert_equal R::MarketData.reciprocal('159'),q['high']
      assert_equal R::MarketData.reciprocal('162'),q['low']
      assert_equal 'USD',q['local_currency']
      assert_equal 'JPY',q['base_currency']
      assert_equal '160.0',q['inverse_rate']
      assert_equal R::MarketData::FX_PRICING,q['pricing_method']
      assert_equal Time.current.to_i,Time.iso8601(q['source_time']).to_i
    end
    assert_equal '0.006211180124223602',R::MarketData.reciprocal('161')
    %w[0 -1 NaN Infinity].each { |bad| assert_raises(R::Error) { R::MarketData.reciprocal(bad) } }
    assert_nil R::MarketData.optional_reciprocal('0')
  end

  def test_forex_immediate_order_preview_matches_execution_spread_and_balance
    travel_to(Time.utc(2026,10,7,12)) do
      fund(@alice); fund(@bob)
      item=forex
      item.update!(quote:quote('0.0063').merge('pricing_method'=>R::MarketData::FX_PRICING),history:Array.new(20) { |n| {'price'=>n.even? ? '0.0063' : '0.0064'} })
      preview=R::MarketListing.execution_prices(item)
      assert_equal '0.0063315',preview['long']
      assert_equal '0.0062685',preview['short']
      assert_equal preview,R::MarketListing.rows([item]).first[:execution_prices]
      [['long',@alice],['short',@bob]].each do |side,user|
        order=R::Exchange.submit(actor:user,instrument_id:item.id,side:side,quantity:'100',leverage:1,request_id:SecureRandom.uuid)
        row=R::Order.find(order['order_id'])
        assert_equal 'filled',row.status
        assert_equal preview[side],row.details['price']
      end
      item.update!(quote:item.quote.merge('ask'=>'0.00634','bid'=>'0.00626'))
      assert_equal({'long'=>'0.00634','short'=>'0.00626'},R::MarketListing.execution_prices(item))
      item.update!(quote:item.quote.merge('delay_seconds'=>900))
      assert_nil R::MarketListing.execution_prices(item)
      item.update!(category:'crypto')
      assert_nil R::MarketListing.execution_prices(item)
    end
  end

  def test_forex_old_aliases_do_not_create_duplicate_markets
    item=forex;SiteSetting.rsc_market_data_enabled=true
    assert_equal ['yahoo','JPY=X'],R::Catalog.provider({'symbol'=>'FX:JPY'})
    with_provider(->(*) { flunk 'Existing market must not contact provider' }) do
      %w[JPY=X JPYUSD=X FX:JPY].each do |code|
        result=R::Catalog.approve(actor:@admin,symbol:code,reason:'test aliases',request_id:SecureRandom.uuid)
        assert_equal item.id,result['instrument_id']
      end
    end
    assert_equal 1,R::Instrument.count
  end

  def test_forex_stale_precision_cache_is_corrected_once_even_when_closed
    travel_to(Time.utc(2026,10,4,10)) do
      item=forex;SiteSetting.rsc_market_data_enabled=true
      item.update!(quote:quote('0.0063'),synced_at:Time.current)
      assert R::MarketData.refresh_due?(item)
      item.update!(provider_error:'provider_busy')
      refute R::MarketData.refresh_due?(item)
      item.update!(provider_error:nil)
      old=R::HistoryCache.create!(instrument_id:item.id,range:'1d',source:'provider',currency:'USD',candles:[{at:Time.current.iso8601,close:'0.0063'}],updated_at:Time.current)
      calls=0
      with_provider(->(*) { calls+=1;chart }) do
        history=R::MarketData.history(item,'1d')
        assert_equal '0.00625',history[:candles].last[:close]
        assert_equal '0.006289308176100628',history[:candles].last[:high]
        assert_equal '0.006211180124223602',history[:candles].last[:low]
        assert_equal 'USD',history[:currency]
        R::MarketData.history(item,'1d')
        assert_equal 1,calls
        R::MarketData.refresh_if_needed(item.id)
      end
      assert_equal R::MarketData::FX_PRICING,old.reload.source
      refute R::MarketData.refresh_due?(item.reload)
      assert_equal '0.00625',item.quote['price']
    end
  end

  def test_forex_failed_refresh_retains_old_chart_with_stale_warning
    item=forex;SiteSetting.rsc_market_data_enabled=true
    cache=R::HistoryCache.create!(instrument_id:item.id,range:'1d',source:'provider',currency:'USD',candles:[{at:Time.current.iso8601,close:'0.0063'}])
    with_provider(->(*) { raise R::Error.new('provider_busy') }) do
      result=R::MarketData.history(item,'1d')
      assert result[:stale]
      assert_equal 'provider_busy',result[:refresh_error]
      assert_equal '0.0063',result[:candles].first['close']
    end
    assert_equal 'provider',cache.reload.source
    assert_equal 'quote_stale',assert_raises(R::Error) { R::Exchange.price!(item,trading:true) }.code
  end

  def test_forex_stock_conversion_uses_precise_rate_and_pence
    Discourse.cache.delete('rsc:fx:v2:JPY');Discourse.cache.delete('rsc:fx:v2:GBP')
    with_provider(->(_host,path,*) { chart(path.include?('GBP') ? '0.8' : '160') }) do
      assert_equal BigDecimal('0.00625'),R::MarketData.usd_rate('JPY')
      assert_equal BigDecimal('0.0125'),R::MarketData.usd_rate('GBp')
    end
  ensure
    Discourse.cache.delete('rsc:fx:v2:JPY');Discourse.cache.delete('rsc:fx:v2:GBP')
  end

  def test_forex_long_short_protection_and_cost_basis_survive_quote_correction
    travel_to(Time.utc(2026,10,7,12)) do
      fund(@alice);fund(@bob)
      item=forex
      q=with_provider(chart) { R::MarketData.fetch_quote(item) }
      item.update!(quote:q)
      [['long',@alice,'0.007000000000000001','0.006000000000000001'],['short',@bob,'0.005000000000000001','0.007000000000000001']].each do |side,user,tp,sl|
        order=R::Exchange.submit(actor:user,instrument_id:item.id,side:side,quantity:'160.01',leverage:1,request_id:SecureRandom.uuid,take_profit:tp,stop_loss:sl)
        assert_equal 'filled',R::Order.find(order['order_id']).status
        position=R::Position.find_by!(user_id:user.id,instrument_id:item.id)
        assert_equal R::Amount.parse(tp),position.take_profit_units
        assert_equal R::Amount.parse(sl),position.stop_loss_units
        assert_equal R::Amount.parse('0.00625'),position.average_units
      end
      before=R::Position.order(:id).pluck(:id,:average_units,:quantity_units,:margin_units)
      ledger=[R::Journal.count,R::Entry.count]
      with_provider(chart('159')) { assert R::MarketData.sync_one(item) }
      assert_equal before,R::Position.order(:id).pluck(:id,:average_units,:quantity_units,:margin_units)
      assert_equal ledger,[R::Journal.count,R::Entry.count]
      assert_operator R::Exchange.pnl(R::Position.find_by!(user_id:@alice.id),R::Amount.parse(item.reload.quote['price'])),:>,0
      assert_operator R::Exchange.pnl(R::Position.find_by!(user_id:@bob.id),R::Amount.parse(item.quote['price'])),:<,0
    end
  end
end
