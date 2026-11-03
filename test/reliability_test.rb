# frozen_string_literal: true
require '/rsc/test/native_adaptation_test'
class ReliabilityTest < NativeAdaptationTest
  NativeAdaptationTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def api
    session=ActionDispatch::Integration::Session.new(Rails.application)
    session.host!('rsc.test'); session.https!
    key=ApiKey.create!(user_id:@alice.id,created_by_id:@admin.id,description:'isolated reliability test')
    yield session, {'Api-Key'=>key.key,'Api-Username'=>@alice.username}
  ensure
    key&.destroy!
  end

  def test_rejection_audit_keeps_safe_context_and_stable_code_once
    fund; item=instrument
    api do |session,headers|
      session.post '/rsc/orders.json',headers:headers,params:{instrument_id:item.id,side:'long',quantity:'0',leverage:'100',high_risk:true,request_id:'rejected-quantity',private_secret:'must-not-be-recorded'}
      assert_equal 422,session.response.status
      audit=R::Audit.where(action:'order_rejected').sole
      assert_equal 'invalid_amount',audit.details['error']
      assert_equal 'true',audit.details['high_risk']
      assert_equal '1000',audit.details['available_balance_snapshot']
      assert_equal item.quote['source_time'],audit.details.dig('quote_snapshot','source_time')
      refute_includes audit.details.to_json,'must-not-be-recorded'
      refute_includes audit.details.to_json,headers['Api-Key']
    end
  end

  def test_protection_http_saves_without_quote_and_reports_precise_rejection
    fund; item=instrument; fill(item,order(item)); position=R::Position.first!
    item.update!(quote:{})
    api do |session,headers|
      endpoint="/rsc/positions/#{position.id}/protection.json"
      session.post endpoint,headers:headers,params:{take_profit:'120',stop_loss:'90',request_id:'protect-no-quote'}
      assert_equal 200,session.response.status
      body=JSON.parse(session.response.body)
      assert body['protection_saved']; assert body['protection_waiting_quote']; refute body.key?('waiting_quote')
      assert_equal 1,R::Order.count
      session.post endpoint,headers:headers,params:{take_profit:'99',request_id:'protect-bad-price'}
      assert_equal 422,session.response.status
      body=JSON.parse(session.response.body)
      assert_equal 'take_profit_not_profitable',body['error_code']
      assert_match(/止盈价须大于保本价/,body['errors'].first)
      assert_equal 'take_profit',body.dig('error_details','field')
      audit=R::Audit.where(action:'request_rejected').sole
      assert_equal 'dashboard.protect',audit.details['operation']
      assert_equal item.id,audit.details['instrument_id']
    end
  end

  def test_failed_audit_cannot_replace_original_response
    fund; item=instrument
    old=R::Audit.method(:create!)
    R::Audit.define_singleton_method(:create!) { |*| raise ActiveRecord::StatementInvalid,'isolated audit failure' }
    api do |session,headers|
      session.post '/rsc/orders.json',headers:headers,params:{instrument_id:item.id,side:'long',quantity:'0',leverage:'1',request_id:'audit-fail-safe'}
      assert_equal 422,session.response.status
      assert_equal 'invalid_amount',JSON.parse(session.response.body)['error_code']
    end
  ensure
    R::Audit.define_singleton_method(:create!,old) if old
  end

  def test_sports_cooldown_stops_fanout_and_later_run_resumes
    Discourse.redis.del('rsc:sports-next-source') # Independent of previous suite runs.
    SiteSetting.rsc_sports_leagues='soccer:eng.1|basketball:nba'
    old=R::ProviderHttp.method(:get);calls=[]
    R::ProviderHttp.define_singleton_method(:get) { |*args,**kwargs| calls << [args,kwargs];raise R::Error.new('provider_cooldown') }
    result=R::SportsData.sync
    assert_equal 1,calls.length
    assert result['pending_recheck'][:deferred]
    assert_equal 1,R::Audit.where(action:'sports_sync_failed').count
    cursor=Discourse.redis.get('rsc:sports-next-source').to_i
    assert_operator cursor,:>,0
    calls.clear
    R::ProviderHttp.define_singleton_method(:get) { |*args,**kwargs| calls << [args,kwargs];{'events'=>[]} }
    result=R::SportsData.sync
    assert result['soccer:eng.1']; assert result['basketball:nba']
    assert_equal 2*R::SportsData.date_buckets.size,calls.length
  ensure
    R::ProviderHttp.define_singleton_method(:get,old) if old
  end
end
