# frozen_string_literal: true
require_relative 'forecast_discovery_test'
class ForecastTest
  def catalog_raw
    @raw.merge('id'=>'901','conditionId'=>'0x'+'9'*64,'slug'=>'catalog-demo','question'=>'Will the new space mission launch?',
      'events'=>[{'id'=>'event-901','title'=>'Space mission'}],'liquidity'=>'900','volume24hr'=>'15','createdAt'=>Time.current.iso8601)
  end
  def catalog_provider(raw=catalog_raw, empty_book:false)
    original=R::ForecastProvider.method(:get)
    R::ForecastProvider.define_singleton_method(:get) do |host,path,query={}|
      case host
      when R::ForecastProvider::GAMMA
        if path.include?('/events/slug/')
          {'id'=>'event-901','title'=>'Space mission','markets'=>[raw]}
        elsif path=='/markets'
          [raw]
        else
          raw
        end
      when R::ForecastProvider::DATA
        {'data'=>[]}
      when R::ForecastProvider::CLOB
        {'market'=>raw['conditionId'],'asset_id'=>query[:token_id],'timestamp'=>(Time.current.to_f*1000).to_i.to_s,
          'asks'=>empty_book ? [] : [{'price'=>'0.5','size'=>'1000'}],'bids'=>[{'price'=>'0.4','size'=>'1000'}]}
      end
    end
    yield
  ensure
    R::ForecastProvider.define_singleton_method(:get,original)
  end
  def request_catalog(user=@alice,request_id=SecureRandom.uuid)
    R::ForecastListing.submit(actor:user,external_id:'901',reason:'Interested in science',request_id:request_id)
  end
  def review_catalog(decision='approved',request_id=SecureRandom.uuid,actor=@admin)
    R::ForecastListing.review(actor:actor,external_id:'901',decision:decision,reason:'Reviewed original rules',request_id:request_id)
  end

  def test_browse_groups_events_and_does_not_require_listing_threshold
    entries=30.times.map do |i|
      R::ForecastCatalog.entry(catalog_raw.merge('id'=>(901+i).to_s,'events'=>[{'id'=>"event-#{i/2}",'title'=>"Topic #{i/2}"}]),'technology')
    end
    assert_equal 30,entries.compact.size
    R::ForecastCatalog.publish(entries)
    result=R::ForecastCatalog.browse(actor:@alice)
    assert_equal 15,result[:total]
    assert_equal 30,result[:market_count]
    assert result[:grouped]
    assert_equal 2,result[:markets].first['related_count']
    expanded=R::ForecastCatalog.browse(actor:@alice,event_id:'event-0')
    assert_equal 2,expanded[:total]
    refute expanded[:grouped]
    assert_equal 1,R::ForecastMarket.count
    assert_empty R::ForecastRequest.all
    assert_equal 0,R::ForecastCatalog.browse(actor:@alice,query:'not a match')[:total]
    assert_equal 0,R::ForecastCatalog.browse(actor:@alice,category:'culture')[:total]
  end

  def test_browse_pagination_is_bounded
    entries=60.times.map do |i|
      R::ForecastCatalog.entry(catalog_raw.merge('id'=>(901+i).to_s,'events'=>[{'id'=>"event-#{i}",'title'=>"Topic #{i}"}]),'technology')
    end
    R::ForecastCatalog.publish(entries)
    result=R::ForecastCatalog.browse(actor:@alice,page:999)
    assert_equal 3,result[:page]
    assert_equal 12,result[:markets].size
    assert_equal 24,R::ForecastCatalog.browse(actor:@alice,page:-1)[:markets].size
  end

  def test_preview_and_link_lookup_never_create_tradable_market
    catalog_provider do
      assert_equal '901',R::ForecastCatalog.preview('901')['id']
      assert_equal 1,R::ForecastCatalog.browse(actor:@alice,query:'https://polymarket.com/event/catalog-demo')[:total]
      assert_equal 1,R::ForecastMarket.count
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
    %w[https://evil.example/event/test https://polymarket.com.evil.test/event/test http://127.0.0.1/event/test https://x@polymarket.com/event/test https://polymarket.com:8443/event/test https://polymarket.com/event/../../etc/passwd].each do |url|
      assert_equal 'forecast_invalid_reference',assert_raises(R::Error) { R::ForecastCatalog.reference(url) }.code
    end
  end

  def test_request_duplicate_and_approval_do_not_move_money
    catalog_provider do
      journals=R::Journal.count
      id=SecureRandom.uuid
      first=request_catalog(@alice,id)
      assert_equal 'pending',first['status']
      assert request_catalog(@alice,id)['replayed']
      request_catalog
      request_catalog(@bob)
      assert_equal 2,R::ForecastRequest.count
      assert_nil R::ForecastMarket.find_by(external_id:'901')
      assert_equal 'admin_required',assert_raises(R::Error){review_catalog('approved',SecureRandom.uuid,@alice)}.code
      SiteSetting.rsc_notifications_enabled=true
      before=Notification.count
      review_id=SecureRandom.uuid
      result=review_catalog('approved',review_id)
      assert_equal 2,result['reviewed']
      assert review_catalog('approved',review_id)['replayed']
      assert_equal before+2,Notification.count
      assert_equal journals,R::Journal.count
      market=R::ForecastMarket.find_by!(external_id:'901')
      refute market.featured
      assert_equal 2,R::ForecastRequest.where(status:'approved',market_id:market.id).count
      assert_equal '100',R::Account.wallet(@alice.id).balance
      assert_equal "/rsc/forecast?market_id=#{market.id}",Notification.last.data_hash['river_path']
    end
  end

  def test_rejected_request_and_pending_limits
    catalog_provider do
      request_catalog
      review_catalog('rejected')
      assert_nil R::ForecastMarket.find_by(external_id:'901')
      assert_equal 'forecast_request_recent',assert_raises(R::Error){request_catalog}.code
      R::ForecastRequest.first.update!(updated_at:2.days.ago)
      assert_equal 'pending',request_catalog['status']
    end
  end

  def test_china_politics_cannot_be_requested_or_opened_from_link
    raw=catalog_raw.merge('question'=>'Will China invade Taiwan?')
    catalog_provider(raw) do
      assert_equal 'forecast_not_eligible',assert_raises(R::Error){request_catalog}.code
      assert_equal 0,R::ForecastCatalog.browse(actor:@alice,query:'https://polymarket.com/market/catalog-demo')[:total]
      assert_empty R::ForecastRequest.all
    end
  end

  def test_rule_changes_after_request_require_fresh_review
    catalog_provider { request_catalog }
    catalog_provider(catalog_raw.merge('description'=>'New settlement conditions')) do
      assert_equal 'forecast_request_changed',assert_raises(R::Error){review_catalog}.code
      assert_equal 'pending',R::ForecastRequest.first.status
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
  end

  def test_pending_request_is_not_auto_opened_by_featured_rotation
    raw=catalog_raw.merge('liquidity'=>'10000','volume24hr'=>'20000')
    catalog_provider(raw) do
      request_catalog
      assert_empty R::ForecastDiscovery.discover
      assert_nil R::ForecastMarket.find_by(external_id:'901')
      assert_equal 1,R::ForecastCatalog.browse(actor:@alice)[:total]
    end
  end

  def test_approved_market_remains_polled_outside_featured
    catalog_provider do
      request_catalog
      review_catalog
      market=R::ForecastMarket.find_by!(external_id:'901')
      market.update!(synced_at:1.day.ago)
      Discourse.redis.setex('rsc:forecast:discovered',600,'1')
      R::ForecastSettlement.tick
      assert market.reload.synced_at > 1.minute.ago
    end
  end

  def test_request_api_permissions_and_preview
    catalog_provider do
      key=ApiKey.create!(user_id:@alice.id,created_by_id:@admin.id,description:'Disposable forecast catalog test')
      headers={'Api-Key'=>key.key,'Api-Username'=>@alice.username}
      session=ActionDispatch::Integration::Session.new(Rails.application)
      session.host! 'community.test'
      session.get '/rsc/forecast/catalog/901.json',headers:headers
      assert_equal 200,session.response.status,session.response.body
      data=JSON.parse(session.response.body)
      assert data['preview']
      assert_nil data['market_id']
      session.get '/rsc/forecast/requests.json',params:{admin:'true'},headers:headers
      assert_equal 403,session.response.status
      session.post '/rsc/forecast/requests.json',params:{external_id:'901',reason:'Test',request_id:SecureRandom.uuid,user_id:@bob.id},headers:headers,as: :json
      assert_equal 200,session.response.status,session.response.body
      assert_equal @alice.id,R::ForecastRequest.last.user_id
      session.post '/rsc/forecast/requests/review.json',params:{external_id:'901',decision:'approved',request_id:SecureRandom.uuid},headers:headers,as: :json
      assert_equal 403,session.response.status
    ensure
      key&.destroy!
    end
  end
  def test_listing_requires_live_depth_on_both_sides
    catalog_provider { request_catalog }
    catalog_provider(catalog_raw,empty_book:true) do
      assert_equal 'forecast_liquidity',assert_raises(R::Error){review_catalog}.code
      assert_nil R::ForecastMarket.find_by(external_id:'901')
      assert_equal 'pending',R::ForecastRequest.first.status
    end
  end

  def test_pending_request_cap_and_notification_deduplication_under_concurrency
    5.times { |i| R::ForecastRequest.create!(external_id:(950+i).to_s,user_id:@alice.id,question:'Test',terms_digest:'test') }
    catalog_provider do
      assert_equal 'forecast_request_limit',assert_raises(R::Error){request_catalog}.code
      R::ForecastRequest.delete_all
      request_catalog
      SiteSetting.rsc_notifications_enabled=true
      before=Notification.count
      outcomes=2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            begin
              review_catalog
            rescue R::Error => error
              { 'error'=>error.code }
            end
          end
        end
      end.map(&:value)
      assert_equal 1,outcomes.sum { |r| r.fetch('reviewed',0) }
      assert_equal before+1,Notification.count
      assert_equal 1,R::ForecastMarket.where(external_id:'901').count
    end
  end

end
