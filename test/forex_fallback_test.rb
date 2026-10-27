# frozen_string_literal: true
require '/rsc/test/forex_activity_test'
class ForexFallbackTest < ForexActivityTest
  ForexActivityTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  def feeds(primary, data)
    old=R::MarketData.method(:fetch_primary_quote);http=R::ProviderHttp.method(:get)
    R::MarketData.define_singleton_method(:fetch_primary_quote) { |_| raise primary if primary.is_a?(Exception); primary }
    calls=[]
    R::ProviderHttp.define_singleton_method(:get) { |host,path,args| calls << [host,path,args[:symbol]]; data }
    yield calls
  ensure
    R::MarketData.define_singleton_method(:fetch_primary_quote,old)
    R::ProviderHttp.define_singleton_method(:get,http)
  end
  def fx
    item=forex('FX:CNY');item.update!(provider:'yahoo',provider_symbol:'CNYUSD=X');item
  end
  def setup
    super
    SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
    Discourse.cache.delete('rsc:fx-fallback:v1:CNY');Discourse.redis.del('rsc:fx-fallback:slot')
  end
  def teardown
    SiteSetting.rsc_twelve_data_api_key=''
    Discourse.cache.delete('rsc:fx-fallback:v1:CNY');Discourse.redis.del('rsc:fx-fallback:slot')
    super
  end
  def test_fallback_validates_pair_timestamp_reciprocal_and_caches
    item=fx;primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601)
    feeds(primary,{'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>Time.current.to_i}) do |calls|
      result=R::MarketData.fetch_quote(item)
      assert_equal R::MarketData.reciprocal('6.67'),result['price']
      assert_equal 'CNY',result['base_currency'];assert result['fallback']
      assert_equal 'twelve_data',result['source'];assert_equal 0,result['delay_seconds']
      assert_equal result,R::MarketData.fetch_quote(item);assert_equal 1,calls.size
      assert_equal ['api.twelvedata.com','/exchange_rate','USD/CNY'],calls.first
    end
  end
  def test_no_credentials_or_fresh_primary_skips_fallback
    item=fx;primary=quote('0.15')
    feeds(primary,{}) do |calls|
      assert_equal primary,R::MarketData.fetch_quote(item);assert_empty calls
      SiteSetting.rsc_twelve_data_api_key='';primary['source_time']=10.minutes.ago.iso8601
      assert_equal primary,R::MarketData.fetch_quote(item);assert_empty calls
    end
  end
  def test_bad_fallback_never_relabels_stale_primary_or_hides_provider_failure
    item=fx;primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601)
    [{'symbol'=>'USD/CNH','rate'=>'6.67','timestamp'=>Time.current.to_i},
      {'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>10.minutes.ago.to_i},
      {'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>1.minute.from_now.to_i},
      {'symbol'=>'USD/CNY','rate'=>'0','timestamp'=>Time.current.to_i}].each do |data|
      Discourse.redis.del('rsc:fx-fallback:slot')
      feeds(primary,data) { assert_equal primary,R::MarketData.fetch_quote(item) }
    end
    Discourse.redis.del('rsc:fx-fallback:slot')
    feeds(R::Error.new('provider_unavailable'),{}) do
      assert_equal 'provider_unavailable',assert_raises(R::Error){R::MarketData.fetch_quote(item)}.code
    end
  end
end
