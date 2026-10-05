# frozen_string_literal: true
require '/rsc/test/migration_features_test'
class LoadingAndTeamTest < MigrationFeaturesTest
  T = DiscourseRsc::SportsTeamTranslation
  def setup
    super
    PluginStoreRow.where(plugin_name: T::STORE).delete_all
    Rails.cache.delete(T::CACHE_KEY)
    Discourse.redis.keys('rsc:sports:team-*').each { |key| Discourse.redis.del(key) }
  end
  def with_method(target, method, &replacement)
    old=target.method(method)
    target.define_singleton_method(method, &replacement)
    old
  end
  def with_translation(result)
    old=with_method(T,:generate){|_| result}
    yield
  ensure
    T.define_singleton_method(:generate,old)
  end
  def team_match(home='Arsenal', away='Paris FC', sport='soccer')
    R::SportMatch.create!(external_id: SecureRandom.uuid, sport:sport,league:'test',home:home,away:away,starts_at:1.day.from_now,status:'scheduled',odds:{home:'1.5'},odds_at:Time.current)
  end
  def test_loading_team_retranslates_builtins_and_history_and_keeps_identity
    match=team_match
    match.update!(starts_at:100.days.ago,status:'finished')
    before=match.attributes
    rows=T.candidates
    assert_includes rows.map{|r|r['name']},'Arsenal'
    response={translations:rows.map{|r|{key:r['key'],zh:r['name']=='Arsenal' ? '阿森纳足球俱乐部' : '巴黎FC'}}}.to_json
    with_translation(response){assert_equal 2,T.translate(rows)}
    assert_equal before,match.reload.attributes
    I18n.with_locale(:zh_CN){assert_equal '阿森纳足球俱乐部',R::SportsPresentation.team('Arsenal',sport:'soccer')}
    I18n.with_locale(:en){assert_equal 'Arsenal',R::SportsPresentation.team('Arsenal',sport:'soccer')}
    assert_empty T.candidates
    Rails.cache.delete(T::CACHE_KEY)
    assert_equal '巴黎FC',T.lookup('Paris FC',sport:'soccer')
    assert_equal 0,R::Journal.count
  end
  def test_loading_team_manual_names_override_ai_and_sport_collision
    team_match('United','United','soccer');team_match('United','United','basketball')
    rows=T.candidates
    with_translation({translations:rows.map{|r|{key:r['key'],zh:r['sport']=='soccer' ? '足球联队' : '篮球联队'}}}.to_json){assert_equal 2,T.translate(rows)}
    assert_equal '足球联队',T.lookup('United',sport:'soccer')
    assert_equal '篮球联队',T.lookup('United',sport:'basketball')
    SiteSetting.rsc_sports_team_name_overrides='{"SOCCER|United":"人工足球名","United":"通用队名"}'
    assert_equal '人工足球名',T.lookup('United',sport:'soccer')
    assert_equal '通用队名',T.lookup('United',sport:'basketball')
    SiteSetting.rsc_sports_team_name_overrides='{"United":"<img src=x>"}'
    assert_equal '足球联队',T.lookup('United',sport:'soccer')
    SiteSetting.rsc_sports_team_name_overrides='invalid'
    assert_equal '篮球联队',T.lookup('United',sport:'basketball')
  end
  def test_loading_team_rejects_bad_responses_and_read_never_calls_ai
    match=team_match
    rows=T.candidates;k=rows.first['key']
    ['bad','{}',{translations:[{key:'wrong',zh:'错名'}]}.to_json,
     {translations:[{key:k,zh:'甲'},{key:k,zh:'乙'}]}.to_json,
     {translations:[{key:k,zh:'<b>球队</b>'}]}.to_json,
     {translations:[{key:k,zh:'Unrelated English prose'}]}.to_json].each do |bad|
      with_translation(bad){assert_equal 0,T.translate(rows)}
    end
    calls=0;old=with_method(T,:generate){|_|calls+=1;raise 'page must not translate'}
    I18n.with_locale(:zh_CN){3.times{assert_equal '阿森纳',R::Views.matches(@alice.id).find{|r|r[:id]==match.id}[:home_name]}}
    assert_equal 0,calls
  ensure
    T.define_singleton_method(:generate,old) if old
  end
  def test_loading_team_background_budget_and_failure_backoff
    team_match
    SiteSetting.rsc_sports_team_translation_enabled=true
    SiteSetting.rsc_sports_team_translation_daily_limit=1
    calls=0;available=with_method(T,:available?){true};generate=with_method(T,:generate){|_|calls+=1;raise 'provider failed'}
    2.times{T.tick};assert_equal 1,calls
    team_match('Another Club','Other Club')
    T.tick;assert_equal 1,calls
    SiteSetting.rsc_sports_team_translation_daily_limit=2
    T.tick;assert_equal 2,calls
    SiteSetting.rsc_sports_team_translation_enabled=false
    team_match('Yet Another','Final Club');T.tick;assert_equal 2,calls
  ensure
    T.define_singleton_method(:available?,available) if available
    T.define_singleton_method(:generate,generate) if generate
  end
  def state(section=nil, extra={})
    klass=Class.new(R::DashboardController) do
      attr_accessor :audit_user,:payload
      def current_user; audit_user; end
      def render_json_dump(data);self.payload=data;end
    end
    c=klass.new;c.audit_user=@alice;c.params=ActionController::Parameters.new(extra.merge(section:section).compact);c.state;c.payload
  end
  def test_loading_wallet_sports_and_packet_skip_market_work
    team_match
    old=with_method(R::MarketListing,:catalog){raise 'unrelated market lookup'}
    %w[wallet packet sports].each do |section|
      data=state(section)
      assert_empty data[:instruments]
      assert_empty data[:positions]
      assert_equal(section=='sports' ? 1 : 0,data[:matches].size)
      assert_operator JSON.generate(data).bytesize,:<,10000
    end
  ensure
    R::MarketListing.define_singleton_method(:catalog,old) if old
  end
  def build_catalog
    45.times do |n|
      item=R::Instrument.create!(symbol:"QUOTE#{n.to_s.rjust(2,'0')}",name:"Market #{n}",category:"crypto",quote:quote("100"))
      item.update!(name:"Market #{n}",category:'crypto',history:(1..100).map{|i|{at:i.to_s,price:i.to_s}})
    end
  end
  def test_loading_market_pagination_filters_selected_position_and_compatibility
    build_catalog
    R::MarketListing.rows(R::Instrument.limit(1))
    data=state('market',market_category:'all')
    assert_equal 20,data[:market_page][:rows].size
    assert_equal 45,data[:market_page][:pagination][:total]
    assert_equal 3,data[:market_page][:pagination][:pages]
    assert_equal 20,data[:instruments].size
    assert_empty data[:matches]
    assert_empty data[:entries]
    first=data[:instruments].map{|r|r[:id]}
    chosen=first.first
    second=state('market',market_category:'all',market_page:2,instrument_id:chosen)
    assert_equal 21,second[:instruments].size
    assert_includes second[:instruments].map{|r|r[:id]},chosen
    assert_empty first & second[:market_page][:rows].map{|r|r[:id]}
    last=state('market',market_category:'all',market_page:100)
    assert_equal 5,last[:market_page][:rows].size
    found=state('market',market_category:'all',market_search:'QUOTE44')
    assert_equal 1,found[:market_page][:rows].size
    assert_equal 'QUOTE44',found[:market_page][:rows].first[:symbol]
    assert_equal 45,state[:instruments].size
  end
  def test_loading_page_state_does_not_use_another_users_wallet_or_positions
    fund(@alice,'100');fund(@bob,'300')
    item=instrument
    R::Exchange.submit(actor:@bob,instrument_id:item.id,side:'long',quantity:'1',leverage:1,request_id:SecureRandom.uuid)
    data=state('market',market_category:'all')
    assert_equal '100',data[:wallet][:balance]
    assert_empty data[:positions]
    assert_empty data[:orders]
    assert_equal 1,data[:market_page][:pagination][:total]
  end
  def test_loading_history_projection_preserves_tail_and_exact_quote
    item=instrument
    history=(1..100).map{|n|{"at"=>n.to_s,"price"=>n.to_s}}
    item.update!(history:history,quote:item.quote.merge('price'=>'0.000000012345678901'))
    row=R::MarketListing.catalog.first
    assert_equal history.last(16),row[:history]
    assert_equal '0.000000012345678901',row[:quote]['price']
    assert_equal history,item.reload.history
  end
  def test_loading_tradable_filter_and_change_sort
    build_catalog
    rows=R::Instrument.order(:id).to_a
    rows[0].update!(quote:rows[0].quote.merge('price'=>'120','previous_close'=>'100'))
    rows[1].update!(quote:rows[1].quote.merge('price'=>'80','previous_close'=>'100'))
    rows[2].update!(quote:rows[2].quote.merge('source_time'=>10.minutes.ago.iso8601))
    gain=state('market',market_category:'all',market_sort:'gainers')[:market_page][:rows]
    loss=state('market',market_category:'all',market_sort:'losers')[:market_page][:rows]
    assert_equal rows[0].id,gain.first[:id]
    assert_equal rows[1].id,loss.first[:id]
    tradable=state('market',market_category:'tradable')[:market_page]
    assert_equal 44,tradable[:pagination][:total]
    refute_includes tradable[:rows].map{|r|r[:id]},rows[2].id
  end
end
