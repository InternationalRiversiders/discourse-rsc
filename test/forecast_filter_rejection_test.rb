# frozen_string_literal: true
require_relative 'forecast_auto_review_test'
class ForecastTest
  def test_missing_provider_metadata_cannot_approve
    assert_equal 'forecast_ai_invalid', assert_raises(R::Error) {
      R::ForecastAutoReview.capture_completion { |_capture| {decision:'approve',reason:'Allowed'}.to_json }
    }.code
  end

  def captured_completion(body, text: '', fail_after_log: false)
    R::ForecastAutoReview.capture_completion do |capture|
      capture.add_from_audit_log(Struct.new(:raw_response_payload).new(body.is_a?(String) ? body : body.to_json))
      raise IOError, 'Synthetic provider failure' if fail_after_log
      text
    end
  end

  def test_content_filter_rejects_even_valid_approval_text_once
    SiteSetting.rsc_forecast_auto_review_enabled = true
    SiteSetting.rsc_notifications_enabled = true
    result = captured_completion({'choices'=>[{'finish_reason'=>'content_filter','message'=>{'content'=>'partial'}}]},
      text: {decision:'approve',reason:'Allowed'}.to_json)
    catalog_provider do
      request_catalog; request_catalog(@bob)
      before = Notification.count
      journals = R::Journal.count
      auto_model(result) { 2.times { R::ForecastAutoReview.tick } }
      assert_equal 2, R::ForecastRequest.where(status:'rejected').count
      assert_match(/内容过滤或拒答/, R::ForecastRequest.first.review_reason)
      assert_equal before+2, Notification.count
      assert_equal 1, @ai_calls.size
      assert_equal journals, R::Journal.count
      assert_nil R::ForecastMarket.find_by(external_id:'901')
      receipt = PluginStore.get(R::ForecastAutoReview::STORE,R::ForecastRequest.first.id.to_s)
      assert_equal 'content_filter', receipt.dig('verdict','provider_signal')
    end
  end

  def test_explicit_refusal_field_and_filter_error_are_rejections
    attrs = R::ForecastProvider.parse(catalog_raw)
    [
      {'choices'=>[{'finish_reason'=>'stop','message'=>{'refusal'=>'Cannot fulfill this request'}}]},
      {'error'=>{'code'=>'content_policy_violation','message'=>'Filtered'}},
      {'error'=>{'code'=>'content_filter','message'=>'Filtered'}}
    ].each do |body|
      result = captured_completion(body,fail_after_log:body.key?('error'))
      auto_model(result) { assert_equal 'reject',R::ForecastAutoReview.classify(attrs)['decision'] }
    end
  end

  def test_plain_refusal_is_rejected_but_normal_review_explanations_are_not
    attrs = R::ForecastProvider.parse(catalog_raw)
    ['抱歉，我无法回答这个问题。', "Sorry, I cannot assist with that request."].each do |text|
      auto_model(text) { assert_equal 'reject',R::ForecastAutoReview.classify(attrs)['decision'] }
    end
    normal = {decision:'approve',reason:'本问题不属于“抱歉，我无法回答”的情况。'}.to_json
    auto_model(normal) { assert_equal 'approve',R::ForecastAutoReview.classify(attrs)['decision'] }
  end

  def test_technical_errors_are_not_content_rejections
    [
      {'error'=>{'code'=>'invalid_api_key','message'=>'Unauthorized'}},
      {'error'=>{'code'=>'rate_limit_exceeded','message'=>'Retry later'}},
      'Service unavailable'
    ].each do |body|
      assert_raises(IOError) { captured_completion(body,fail_after_log:true) }
    end
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      auto_model(->(_attrs){raise IOError,'Synthetic timeout'}) { R::ForecastAutoReview.tick }
      request = R::ForecastRequest.first
      assert_equal 'pending',request.status
      assert_equal 'retry',R::ForecastAutoReview.receipt(request)['status']
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
  end

  def test_empty_or_truncated_responses_stay_pending
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      completion=captured_completion({'choices'=>[{'finish_reason'=>'length','message'=>{'content'=>'{"decision":'}}]},text:'{"decision":')
      auto_model(completion) { R::ForecastAutoReview.tick }
      assert_equal 'pending',R::ForecastRequest.first.status
      assert_equal 'retry',R::ForecastAutoReview.receipt(R::ForecastRequest.first)['status']
    end
    attrs=R::ForecastProvider.parse(catalog_raw)
    auto_model(captured_completion({'choices'=>[{'finish_reason'=>'stop','message'=>{'content'=>nil}}]},text:nil)) do
      assert_equal 'forecast_ai_invalid',assert_raises(R::Error){R::ForecastAutoReview.classify(attrs)}.code
    end
  end

  def test_filtered_response_cannot_override_a_disabled_switch
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      result=captured_completion({'choices'=>[{'finish_reason'=>'content_filter'}]})
      auto_model(->(_attrs){SiteSetting.rsc_forecast_auto_review_enabled=false;result}) { R::ForecastAutoReview.tick }
      assert_equal 'pending',R::ForecastRequest.first.status
      assert_nil R::ForecastMarket.find_by(external_id:'901')
    end
  end
end
