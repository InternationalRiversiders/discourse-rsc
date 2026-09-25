# frozen_string_literal: true
require_relative 'forecast_catalog_test'
class ForecastTest
  alias_method :setup_without_auto_review, :setup
  def setup
    setup_without_auto_review
    SiteSetting.rsc_forecast_auto_review_enabled = false
    SiteSetting.rsc_forecast_auto_review_daily_limit = 100
    SiteSetting.rsc_forecast_translation_model_id = 1
    PluginStoreRow.where(plugin_name: R::ForecastAutoReview::STORE).delete_all
    Discourse.redis.del("rsc:forecast:auto-review-budget:#{Time.now.utc.strftime('%Y%m%d')}")
  end

  def auto_model(result = {decision:'approve',reason:'普通科学问题，不涉及中国政治。'}.to_json)
    original_generate = R::ForecastAutoReview.method(:generate)
    original_configured = R::ForecastAutoReview.method(:configured?)
    @ai_calls = []
    calls = @ai_calls
    R::ForecastAutoReview.define_singleton_method(:configured?) { true }
    R::ForecastAutoReview.define_singleton_method(:generate) do |attrs|
      calls << attrs
      result.respond_to?(:call) ? result.call(attrs) : result
    end
    yield
  ensure
    R::ForecastAutoReview.define_singleton_method(:generate, original_generate)
    R::ForecastAutoReview.define_singleton_method(:configured?, original_configured)
  end

  def test_auto_review_off_never_calls_model_or_changes_request
    catalog_provider do
      request_catalog
      auto_model { R::ForecastAutoReview.tick }
      assert_empty @ai_calls
      assert_equal 'pending', R::ForecastRequest.first.status
    end
  end

  def test_auto_approval_uses_existing_atomic_listing_and_notifications
    SiteSetting.rsc_forecast_auto_review_enabled = true
    SiteSetting.rsc_notifications_enabled = true
    catalog_provider do
      request_catalog; request_catalog(@bob)
      before = Notification.count
      journals = R::Journal.count
      auto_model { 2.times { R::ForecastAutoReview.tick } }
      assert_equal 1, @ai_calls.size
      assert_equal 2, R::ForecastRequest.where(status:'approved',reviewer_id:Discourse.system_user.id).count
      assert_equal before + 2, Notification.count
      assert_equal journals, R::Journal.count
      assert_equal 1, R::ForecastMarket.where(external_id:'901').count
      assert R::Audit.where(action:'forecast_request_review').last.details['automated']
    end
  end

  def test_ai_rejection_does_not_create_market
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      auto_model({decision:'reject',reason:'涉及中国政治相关内容。'}.to_json) { R::ForecastAutoReview.tick }
      assert_equal 'rejected', R::ForecastRequest.first.status
      assert_match(/AI 自动审核/, R::ForecastRequest.first.review_reason)
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
  end

  def test_keyword_policy_cannot_be_overridden_by_model_and_ordinary_chinese_sports_allowed
    auto_model do
      attrs = R::ForecastProvider.parse(catalog_raw.merge('question'=>'Will China invade Taiwan?'))
      assert_equal 'reject', R::ForecastAutoReview.classify(attrs)['decision']
      assert_empty @ai_calls
      attrs = R::ForecastProvider.parse(catalog_raw.merge('question'=>'Will China win the next Olympic table tennis championship?'))
      assert_equal 'approve', R::ForecastAutoReview.classify(attrs)['decision']
      assert_equal 1, @ai_calls.size
      assert_equal %i[question event_title outcomes rules].sort, @ai_calls.first.slice(:question,:event_title,:outcomes,:rules).keys.sort
    end
  end

  def test_uncertain_verdict_stays_pending_without_repeated_calls
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      auto_model({decision:'manual',reason:'背景信息不足。'}.to_json) { 2.times { R::ForecastAutoReview.tick } }
      assert_equal 1, @ai_calls.size
      request = R::ForecastRequest.first
      assert_equal 'pending', request.status
      assert_equal 'manual', R::ForecastAutoReview.presentation(request)['status']
    end
  end

  def test_invalid_ai_output_retries_with_backoff_then_stays_manual
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      auto_model('approve whatever') do
        3.times do
          R::ForecastAutoReview.tick
          request = R::ForecastRequest.first
          receipt = R::ForecastAutoReview.receipt(request)
          assert_equal 'pending', request.status
          R::ForecastAutoReview.record(request, receipt.merge('retry_at'=>0))
        end
        R::ForecastAutoReview.tick
      end
      assert_equal 3, @ai_calls.size
      assert_equal 'manual', R::ForecastAutoReview.receipt(R::ForecastRequest.first)['status']
    end
  end

  def test_disable_during_ai_response_prevents_approval
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      auto_model(->(_attrs) { SiteSetting.rsc_forecast_auto_review_enabled=false; {decision:'approve',reason:'可通过。'}.to_json }) { R::ForecastAutoReview.tick }
      assert_equal 'pending', R::ForecastRequest.first.status
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
  end

  def test_event_changes_during_ai_response_cannot_reuse_old_verdict
    SiteSetting.rsc_forecast_auto_review_enabled = true
    raw = catalog_raw
    catalog_provider(raw) do
      request_catalog
      auto_model(->(_attrs) { raw['events'][0]['title']='Different event context'; {decision:'approve',reason:'可通过。'}.to_json }) { R::ForecastAutoReview.tick }
      assert_equal 'pending', R::ForecastRequest.first.status
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
  end

  def test_manual_rejection_wins_over_in_flight_ai_approval
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      auto_model(->(_attrs) { review_catalog('rejected'); {decision:'approve',reason:'可通过。'}.to_json }) { R::ForecastAutoReview.tick }
      assert_equal 'rejected', R::ForecastRequest.first.status
      assert_equal @admin.id, R::ForecastRequest.first.reviewer_id
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
  end

  def test_auto_approval_still_requires_live_depth
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider { request_catalog }
    catalog_provider(catalog_raw,empty_book:true) do
      auto_model { R::ForecastAutoReview.tick }
      assert_equal 'pending', R::ForecastRequest.first.status
      assert_equal 'manual', R::ForecastAutoReview.receipt(R::ForecastRequest.first)['status']
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
  end

  def test_daily_ai_budget_defers_requests
    SiteSetting.rsc_forecast_auto_review_enabled = true
    SiteSetting.rsc_forecast_auto_review_daily_limit = 1
    Discourse.redis.set("rsc:forecast:auto-review-budget:#{Time.now.utc.strftime('%Y%m%d')}",1)
    catalog_provider do
      request_catalog
      auto_model { R::ForecastAutoReview.tick }
      assert_empty @ai_calls
      assert_equal 'pending', R::ForecastRequest.first.status
    end
  end

  def test_only_rsc_administrators_can_toggle_automatic_review
    auto_model do
      [@alice,@admin].each do |actor|
        key=ApiKey.create!(user_id:actor.id,created_by_id:@admin.id,description:'Disposable automatic-review test')
        begin
          session=ActionDispatch::Integration::Session.new(Rails.application)
          session.host! 'community.test'
          headers={'Api-Key'=>key.key,'Api-Username'=>actor.username}
          session.post '/rsc/forecast/auto-review-settings.json',params:{enabled:true},headers:headers,as: :json
          assert_equal actor.admin? ? 200 : 403,session.response.status,session.response.body
        ensure
          key.destroy!
        end
      end
      assert SiteSetting.rsc_forecast_auto_review_enabled
    end
  end
end
