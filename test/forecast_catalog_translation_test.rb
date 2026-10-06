# frozen_string_literal: true
require_relative 'forecast_catalog_test'
class ForecastTest
  alias_method :catalog_translation_base_setup, :setup
  def setup
    catalog_translation_base_setup
    PluginStoreRow.where(plugin_name: R::ForecastCatalogTranslation::STORE).delete_all
    Discourse.redis.del(R::ForecastTranslation::PREVIEW_QUEUE)
  end

  def cache_catalog(rows)
    rows.each do |row|
      PluginStore.set(R::ForecastCatalogTranslation::STORE, row['external_id'],
        { question: '新的太空任务会发射吗？', event_title: '太空任务', outcomes: %w[是 否],
          signature: R::ForecastCatalogTranslation.signature(row) })
    end
  end

  def test_catalog_translation_covers_unlisted_search_and_event_title_without_listing
    row = R::ForecastCatalog.entry(catalog_raw)
    R::ForecastCatalog.publish([row])
    before = R::Journal.count
    cache_catalog([row])
    result = R::ForecastCatalog.browse(actor: @alice, query: '太空')
    assert_equal 1, result[:total]
    assert_equal '太空任务', result[:markets].first['event_title']
    assert_equal %w[是 否], result[:markets].first['outcomes']
    assert_equal 1, R::ForecastCatalog.browse(actor: @alice, query: 'space mission')[:total]
    assert_nil R::ForecastMarket.find_by(external_id: '901')
    assert_empty R::ForecastRequest.all
    assert_equal before, R::Journal.count
    preview = R::ForecastMarket.new(R::ForecastProvider.parse(catalog_raw))
    view = R::ForecastTranslation.presentation(preview)
    assert view[:translated]
    refute view[:rules_translated]
    assert_equal preview.rules, view[:rules]
  end

  def test_catalog_translation_invalidates_changed_source_and_model
    row = R::ForecastCatalog.entry(catalog_raw)
    cache_catalog([row])
    refute R::ForecastCatalogTranslation.cached(row.merge('question' => 'Changed terms?'))
    previous = SiteSetting.rsc_forecast_translation_model_id
    SiteSetting.rsc_forecast_translation_model_id = previous + 1
    refute R::ForecastCatalogTranslation.cached(row)
  ensure
    SiteSetting.rsc_forecast_translation_model_id = previous if previous
  end

  def test_preview_full_translation_survives_listing_and_does_not_create_market
    raw = catalog_raw
    preview = R::ForecastMarket.new(R::ForecastProvider.parse(raw))
    translated_with(translation_result) { assert R::ForecastTranslation.translate(preview) }
    assert R::ForecastTranslation.presentation(preview)[:rules_translated]
    assert_nil R::ForecastMarket.find_by(external_id: '901')
    listed = R::ForecastProvider.ingest(raw, featured: false)
    assert R::ForecastTranslation.cached(listed)
    assert_equal raw['description'], listed.rules
    assert_equal '合成测试：最终确认决定每份兑付。', R::ForecastTranslation.presentation(listed)[:rules]
  end

  def test_refresh_missing_event_metadata_keeps_translation_and_real_metadata_changes_invalidate
    raw = @raw.merge('events' => [{'title' => 'Original event group'}])
    R::ForecastProvider.ingest(raw)
    @market.reload
    translated_with(translation_result) { assert R::ForecastTranslation.translate(@market) }
    R::ForecastProvider.ingest(@raw)
    assert_equal 'Original event group', @market.reload.event_title
    assert R::ForecastTranslation.cached(@market)
    R::ForecastProvider.ingest(raw.merge('events' => [{'title' => 'New event group'}]))
    assert_nil R::ForecastTranslation.cached(@market.reload)
  end

  def test_translation_shared_budget_stops_exactly_at_limit
    key = "rsc:forecast:translation-budget:#{Time.now.utc.strftime('%Y%m%d')}"
    Discourse.redis.set(key, SiteSetting.rsc_forecast_translation_daily_limit - 1)
    assert R::ForecastTranslation.reserve_budget
    refute R::ForecastTranslation.reserve_budget
    assert_equal SiteSetting.rsc_forecast_translation_daily_limit, Discourse.redis.get(key).to_i
  ensure
    Discourse.redis.del(key)
  end

  def test_automatic_tick_ignores_unlisted_catalog_and_unapproved_markets
    R::ForecastCatalog.publish([R::ForecastCatalog.entry(catalog_raw)])
    R::ForecastProvider.ingest(catalog_raw, featured: false)
    enabled = R::ForecastTranslation.method(:enabled?)
    attempt = R::ForecastTranslation.method(:translate_attempt)
    called = []
    R::ForecastTranslation.define_singleton_method(:enabled?) { true }
    R::ForecastTranslation.define_singleton_method(:translate_attempt) { |market| called << market.id }
    R::ForecastTranslation.tick
    assert_equal [@market.id], called
    assert_empty PluginStoreRow.where(plugin_name: R::ForecastCatalogTranslation::STORE)
  ensure
    R::ForecastTranslation.define_singleton_method(:enabled?, enabled)
    R::ForecastTranslation.define_singleton_method(:translate_attempt, attempt)
  end

  def test_unlisted_preview_does_not_enqueue_ai_translation
    original = R::ForecastTranslation.method(:enabled?)
    R::ForecastTranslation.define_singleton_method(:enabled?) { true }
    market = R::ForecastMarket.new(R::ForecastProvider.parse(catalog_raw))
    refute R::ForecastTranslation.enqueue(market)
    assert_equal 0, Discourse.redis.zcard(R::ForecastTranslation::PREVIEW_QUEUE)
    market = R::ForecastProvider.ingest(catalog_raw, featured: false)
    refute R::ForecastTranslation.enqueue(market)
    market.update!(featured: true)
    assert R::ForecastTranslation.enqueue(market)
    assert R::ForecastTranslation.enqueue(market)
    assert_equal 1, Discourse.redis.zcard(R::ForecastTranslation::PREVIEW_QUEUE)
    translated_with(translation_result) { assert R::ForecastTranslation.translate(market) }
    refute R::ForecastTranslation.enqueue(market)
  ensure
    R::ForecastTranslation.define_singleton_method(:enabled?, original)
  end
end
