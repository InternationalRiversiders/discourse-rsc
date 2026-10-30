# frozen_string_literal: true
require '/rsc/test/forex_quote_guard_test'
class QuoteRefreshTest < ForexQuoteGuardTest
  ForexQuoteGuardTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  def test_closed_session_receives_final_price_without_reopening_trading
    travel_to(Time.utc(2026,10,30,7,1)) do
      item=instrument
      item.update!(provider:'yahoo',symbol:'588370.SS',category:'cn',synced_at:10.minutes.ago,
        metadata:{'trading_hours'=>'09:30-11:30,13:00-15:00 Asia/Shanghai'},
        quote:quote('1.27').merge('source'=>'yahoo','session_start'=>Time.utc(2026,10,30,1,30).iso8601,'session_end'=>Time.utc(2026,10,30,7).iso8601,'received_at'=>10.minutes.ago.iso8601,'source_time'=>25.minutes.ago.iso8601))
      assert R::MarketSessions.closed?(item)
      assert R::MarketData.refresh_due?(item)
      item.update!(quote:item.quote.merge('received_at'=>Time.current.iso8601),synced_at:Time.current)
      refute R::MarketData.refresh_due?(item)
      travel 5.minutes
      assert R::MarketData.refresh_due?(item)
      travel 16.minutes
      item.update!(quote:item.quote.merge('price'=>'1.25','source_time'=>Time.utc(2026,10,30,7).iso8601,'received_at'=>Time.current.iso8601),synced_at:Time.current)
      travel 6.minutes
      refute R::MarketData.refresh_due?(item)
      assert_equal 'market_closed',assert_raises(R::Error){R::Exchange.price!(item,trading:true)}.code
    end
  end
  def test_intraday_forex_chart_never_contains_quarantined_provider_price
    travel_to(Time.utc(2026,10,30,12)) do
      item=forex;item.update!(quote:observation('0.15'),history:[{'at'=>1.minute.ago.iso8601,'price'=>'0.15'}])
      accept(item,'0.1503')
      data=R::MarketData.history(item,'1d')
      assert data[:accepted_quotes]
      assert_equal 'RSC',data[:currency]
      assert_equal ['0.15'],data[:candles].map{|c|c[:close]}
      assert_equal 'pending',data[:instrument][:quote].dig('verification','status')
    end
  end
  def test_quote_and_chart_share_provider_response
    data=JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))
    calls=0
    old=R::ProviderHttp.method(:get)
    R::ProviderHttp.define_singleton_method(:get){|*|calls+=1;data}
    begin
      R::MarketData.yahoo_chart('TEST')
      R::MarketData.yahoo_chart('TEST')
      assert_equal 1,calls
      R::MarketData.yahoo_chart('TEST','5d')
      assert_equal 2,calls
    ensure
      R::ProviderHttp.define_singleton_method(:get,old)
    end
  end
end
