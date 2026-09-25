# frozen_string_literal: true
require_relative 'forecast_translation_test'
class ForecastTest
  alias_method :forecast_translation_setup, :setup
  def setup
    forecast_translation_setup
    PluginStoreRow.where(plugin_name: R::ForecastDiscovery::STORE).delete_all
  end

  def test_editorial_china_politics_filter_keeps_unrelated_topics
    ['Will China invade Taiwan?', 'Will China impose tariffs?', 'Taiwan presidential election winner?',
     'Will Xi Jinping visit Brazil?', 'Hong Kong protests this year?', 'Will the US attack China?',
     '中国会在今年举行选举吗？'].each do |title|
      assert R::ForecastDiscovery.excluded?(question:title),title
    end
    ['Will the U.S. invade Iran?', 'China wins the World Cup?', 'Chinese team wins Counter-Strike?',
     'Will DeepSeek lead the Chinese AI leaderboard?', 'Will Taiwan win the baseball game?',
     'Will a Chinese film win an Oscar?'].each do |title|
      refute R::ForecastDiscovery.excluded?(question:title),title
    end
    assert R::ForecastDiscovery.excluded?(question:'By December?',event_title:'Taiwan election')
  end

  def candidate_pool(count=20)
    R::ForecastDiscovery::QUOTAS.keys.flat_map.with_index do |category,group|
      count.times.map do |i|
        raw=@raw.deep_dup.merge('id'=>(1000+group*100+i).to_s,
          'events'=>[{'id'=>"#{group}-#{i}",'title'=>"Event #{group}-#{i}"}])
        R::ForecastDiscovery.candidates([raw],category).first
      end
    end
  end

  def test_discovery_balances_categories_deduplicates_and_limits_events
    pool=candidate_pool
    selected=R::ForecastDiscovery.select(pool+pool)
    assert_equal 60,selected.size
    assert_equal 60,selected.map{|c|c[:id]}.uniq.size
    assert_equal R::ForecastDiscovery::QUOTAS,selected.group_by{|c|c[:category]}.transform_values(&:size)
    pool.each { |c| c[:event]='same-event' }
    assert_operator R::ForecastDiscovery.select(pool).size,:<=,2
    pool=candidate_pool
    pool.each { |c| c[:family]='musk-posts' }
    assert_equal 2,R::ForecastDiscovery.select(pool).size
  end

  def test_discovery_keeps_quality_and_contract_filters
    bads=[{'liquidity'=>'4999'},{'volume24hr'=>'999'},{'negRiskOther'=>true},{'closed'=>true},
      {'outcomePrices'=>'["0.999","0.001"]'},{'endDate'=>30.minutes.from_now.iso8601},
      {'question'=>'Will China invade Taiwan?'}]
    bads.each do |change|
      assert_empty R::ForecastDiscovery.candidates([@raw.merge(change)],'culture')
    end
    assert_equal 1,R::ForecastDiscovery.candidates([@raw],'culture').size
  end

  def test_failed_discovery_does_not_replace_existing_recommendations
    original=R::ForecastProvider.method(:get)
    calls=0
    raw=@raw
    R::ForecastProvider.define_singleton_method(:get) do |*args|
      calls+=1
      raise R::Error.new('forecast_unavailable') if calls==3
      [raw]
    end
    assert_raises(R::Error){R::ForecastDiscovery.discover}
    assert @market.reload.featured
    assert_empty R::ForecastDiscovery.metadata
  ensure
    R::ForecastProvider.define_singleton_method(:get,original) if original
  end

  def test_valid_discovery_replaces_selection_without_deleting_markets
    original=R::ForecastProvider.method(:get)
    raw=@raw.merge('id'=>'900','conditionId'=>'0x'+'9'*64,'slug'=>'new-event','events'=>[{'id'=>'e900','title'=>'New event'}])
    calls=[]
    R::ForecastProvider.define_singleton_method(:get) do |host,path,query|
      calls << query
      [raw]
    end
    ids=R::ForecastDiscovery.discover
    assert_equal 8,calls.size
    assert calls.all?{|q|q[:limit]==100 && q[:tag_id].present?}
    assert_equal 1,ids.size
    refute @market.reload.featured
    assert_equal 2,R::ForecastMarket.count
    assert_equal 'technology',R::ForecastDiscovery.metadata.dig(ids.first.to_s,'category')
    R::ForecastProvider.define_singleton_method(:get){|*_| []}
    assert_empty R::ForecastDiscovery.discover
    assert_empty R::ForecastMarket.where(featured:true)
    assert_equal 2,R::ForecastMarket.count
  ensure
    R::ForecastProvider.define_singleton_method(:get,original) if original
  end

  def test_state_omits_china_politics_even_before_next_discovery
    @market.update!(question:'Will China invade Taiwan?')
    key=ApiKey.create!(user:@alice,description:'isolated selection test')
    session=ActionDispatch::Integration::Session.new(Rails.application)
    session.get '/rsc/forecast/state.json',headers:{'Api-Key'=>key.key,'Api-Username'=>@alice.username,'Host'=>'community.test'}
    assert_equal 200,session.response.status,session.response.body
    assert_empty JSON.parse(session.response.body)['markets']
    session.get "/rsc/forecast/markets/#{@market.id}.json",headers:{'Api-Key'=>key.key,'Api-Username'=>@alice.username,'Host'=>'community.test'}
    assert_equal 200,session.response.status,session.response.body
    assert R::ForecastMarket.exists?(@market.id)
  ensure
    key&.destroy!
  end
end
