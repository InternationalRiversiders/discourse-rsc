# frozen_string_literal: true
require_relative 'forecast_catalog_translation_test'
require_relative 'forecast_filter_rejection_test'
class ForecastTest
  def test_combined_approval_saves_complete_translation_with_no_second_model_call
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog; request_catalog(@bob)
      auto_model { R::ForecastAutoReview.tick }
      assert_equal 1, @ai_calls.size
      assert_equal 2, R::ForecastRequest.where(status: 'approved').count
      market = R::ForecastMarket.find_by!(external_id: '901')
      assert R::ForecastTranslation.cached(market, fresh: true)
      assert_equal JSON.parse(translation_result)['rules'], R::ForecastTranslation.presentation(market)[:rules]
      assert_equal catalog_raw['description'], market.rules
      assert_equal R::ForecastProvider.parse(catalog_raw)[:terms_digest], market.terms_digest
      # Any standalone translation request would fail, so a cache hit is required.
      translated_with('must not call another model') { assert R::ForecastTranslation.translate(market) }
    end
  end

  def test_approval_missing_or_incomplete_translation_cannot_list_market
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider do
      request_catalog
      [nil, {'question'=>'问题'}, JSON.parse(translation_result).merge('outcomes'=>['是'])].each do |translation|
        auto_model({decision:'approve',reason:'普通事件。',translation:translation}.to_json) { R::ForecastAutoReview.tick }
        request = R::ForecastRequest.first
        assert_equal 'pending', request.status
        assert_nil R::ForecastMarket.find_by(external_id: '901')
        receipt = R::ForecastAutoReview.receipt(request)
        assert_equal 'forecast_ai_invalid', receipt['error']
        R::ForecastAutoReview.record(request, receipt.merge('retry_at'=>0))
      end
    end
  end

  def test_manual_approval_reuses_translation_after_a_technical_listing_failure
    SiteSetting.rsc_forecast_auto_review_enabled = true
    catalog_provider { request_catalog }
    catalog_provider(catalog_raw, empty_book:true) do
      auto_model { R::ForecastAutoReview.tick }
      assert_equal 1, @ai_calls.size
      assert_equal 'manual', R::ForecastAutoReview.receipt(R::ForecastRequest.first)['status']
    end
    catalog_provider { review_catalog }
    market = R::ForecastMarket.find_by!(external_id:'901')
    assert R::ForecastTranslation.cached(market, fresh:true)
  end

  def test_review_retry_reuses_combined_response_without_retranslating
    SiteSetting.rsc_forecast_auto_review_enabled = true
    original = R::ForecastListing.method(:review)
    catalog_provider do
      request_catalog
      R::ForecastListing.define_singleton_method(:review) { |**_args| raise IOError, 'Temporary synthetic failure' }
      auto_model do
        R::ForecastAutoReview.tick
        request = R::ForecastRequest.first
        receipt = R::ForecastAutoReview.receipt(request)
        assert_equal 'retry', receipt['status']
        assert receipt.dig('verdict','translation','rules')
        R::ForecastAutoReview.record(request, receipt.merge('retry_at'=>0))
        R::ForecastListing.define_singleton_method(:review, original)
        R::ForecastAutoReview.tick
        assert_equal 1, @ai_calls.size
        assert_equal 'approved', request.reload.status
        assert R::ForecastTranslation.cached(R::ForecastMarket.find_by!(external_id:'901'), fresh:true)
      end
    end
  ensure
    R::ForecastListing.define_singleton_method(:review, original)
  end
end
