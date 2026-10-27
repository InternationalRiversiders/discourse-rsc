# frozen_string_literal: true
require '/rsc/test/forex_activity_test'
class ForexFallbackTest < ForexActivityTest
  ForexActivityTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  def feeds(primary, data)
    old=R::MarketData.method(:fetch_primary_quote);http=R::ProviderHttp.method(:get)
    R::MarketData.define_singleton_method(:fetch_primary_quote) { |_| raise primary if primary.is_a?(Exception); primary }
    calls=[]
    R::ProviderHttp.define_singleton_method(:get) { |host,path,args| calls << [host,path,args[:symbol]]; raise "Unsupported precision" unless args[:dp] == 11; data }
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
    Discourse.cache.delete('rsc:fx-fallback:v1:CNY');Discourse.redis.del('rsc:fx-fallback:slot', 'rsc:fx-fallback:retry:CNY', "rsc:fx-fallback:requests:#{Time.current.utc.to_date}")
  end
  def teardown
    SiteSetting.rsc_twelve_data_api_key=''
    Discourse.cache.delete('rsc:fx-fallback:v1:CNY');Discourse.redis.del('rsc:fx-fallback:slot', 'rsc:fx-fallback:retry:CNY', "rsc:fx-fallback:requests:#{Time.current.utc.to_date}")
    super
  end
  def test_fallback_validates_pair_timestamp_reciprocal_and_caches
    item=fx;primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601)
    feeds(primary,{'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>Time.current.to_i}) do |calls|
      result=R::MarketData.execution_quote(item,primary)
      assert_equal R::MarketData.reciprocal('6.67'),result['price']
      assert_equal 'CNY',result['base_currency'];assert result['fallback']
      assert_equal 'twelve_data',result['source'];assert_equal 0,result['delay_seconds']
      assert_equal result,R::MarketData.execution_quote(item,primary);assert_equal 1,calls.size
      assert_equal ['api.twelvedata.com','/exchange_rate','USD/CNY'],calls.first
    end
  end
  def test_no_credentials_or_fresh_primary_skips_fallback
    item=fx;primary=quote('0.15')
    feeds(primary,{}) do |calls|
      assert_equal primary,R::MarketData.execution_quote(item,primary);assert_empty calls
      SiteSetting.rsc_twelve_data_api_key='';primary['source_time']=10.minutes.ago.iso8601
      assert_equal primary,R::MarketData.execution_quote(item,primary);assert_empty calls
    end
  end
  def test_bad_fallback_never_relabels_stale_primary_or_hides_provider_failure
    item=fx;primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601)
    [{'symbol'=>'USD/CNH','rate'=>'6.67','timestamp'=>Time.current.to_i},
      {'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>10.minutes.ago.to_i},
      {'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>1.minute.from_now.to_i},
      {'symbol'=>'USD/CNY','rate'=>'0','timestamp'=>Time.current.to_i}].each do |data|
      Discourse.redis.del('rsc:fx-fallback:slot','rsc:fx-fallback:retry:CNY')
      feeds(primary,data) { assert_equal primary,R::MarketData.execution_quote(item,primary) }
    end
    Discourse.redis.del('rsc:fx-fallback:slot','rsc:fx-fallback:retry:CNY')
    feeds(R::Error.new('provider_unavailable'),{}) do
      assert_equal 'provider_unavailable',assert_raises(R::Error){R::MarketData.fetch_quote(item)}.code
    end
  end
  def test_only_execution_uses_backup_even_during_primary_backoff
    travel_to(Time.utc(2026,10,27,12)) do
      item=fx;activity;SiteSetting.rsc_market_data_enabled=true
      primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601,'pricing_method'=>R::MarketData::FX_PRICING)
      item.update!(quote:primary,provider_error:'provider_http_429',synced_at:Time.current)
      feeds(primary,{'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>Time.current.to_i}) do |calls|
        assert_equal primary,R::MarketData.fetch_quote(item)
        %i[read background idle forex_fast protection].each { |purpose| R::MarketData.refresh_if_needed(item.id,purpose:purpose) }
        assert_empty calls
        result=R::MarketData.refresh_if_needed(item.id,purpose: :trade)
        assert_equal 'twelve_data',result.quote['source'];assert_nil result.provider_error
        assert_equal 1,calls.size
        R::MarketData.refresh_if_needed(item.id,purpose: :exit)
        assert_equal 1,calls.size
      end
    end
  end

  def test_closed_market_never_spends_backup_credit
    travel_to(Time.utc(2026,10,24,12)) do
      item=fx;SiteSetting.rsc_market_data_enabled=true
      primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601,'pricing_method'=>R::MarketData::FX_PRICING)
      item.update!(quote:primary)
      feeds(primary,{}) do |calls|
        R::MarketData.refresh_if_needed(item.id,purpose: :exit)
        assert_empty calls
      end
    end
  end

  def test_free_quota_cap_and_failed_pair_backoff
    item=fx;primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601)
    key="rsc:fx-fallback:requests:#{Time.current.utc.to_date}"
    Discourse.redis.set(key,750)
    feeds(primary,{}) do |calls|
      assert_equal primary,R::MarketData.execution_quote(item,primary)
      assert_empty calls
      assert_equal '750',Discourse.redis.get(key)
      Discourse.redis.del(key)
      2.times { assert_equal primary,R::MarketData.execution_quote(item,primary); Discourse.redis.del('rsc:fx-fallback:slot') }
      assert_equal 1,calls.size
      assert_equal '1',Discourse.redis.get(key)
    end
  end

  def test_cached_quote_expiry_refreshes_instead_of_waiting_for_cache_ttl
    item=fx;primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601)
    data={'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>110.seconds.ago.to_i}
    feeds(primary,data) do |calls|
      assert_equal 'twelve_data',R::MarketData.execution_quote(item,primary)['source']
      travel 20.seconds
      Discourse.redis.del('rsc:fx-fallback:slot')
      data['timestamp']=Time.current.to_i
      assert_equal Time.current.to_i,Time.iso8601(R::MarketData.execution_quote(item,primary)['source_time']).to_i
      assert_equal 2,calls.size
    end
  end

end
