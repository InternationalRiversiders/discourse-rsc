# frozen_string_literal: true
require_relative 'forecast_catalog_test'
class ForecastTest
  alias_method :catalog_translation_base_setup, :setup
  def setup
    catalog_translation_base_setup
    PluginStoreRow.where(plugin_name: R::ForecastCatalogTranslation::STORE).delete_all
    Discourse.redis.del(R::ForecastTranslation::PREVIEW_QUEUE)
  end

  def catalog_translation_result(rows)
    { markets: rows.map { |row| { external_id: row['external_id'], question: '新的太空任务会发射吗？',
      event_title: '太空任务', outcomes: %w[是 否] } } }.to_json
  end

  def translated_catalog_with(value)
    original = R::ForecastCatalogTranslation.method(:generate)
    R::ForecastCatalogTranslation.define_singleton_method(:generate) { |_rows| value }
    yield
  ensure
    R::ForecastCatalogTranslation.define_singleton_method(:generate, original)
  end

  def test_catalog_translation_covers_unlisted_search_and_event_title_without_listing
    row = R::ForecastCatalog.entry(catalog_raw)
    R::ForecastCatalog.publish([row])
    before = R::Journal.count
    translated_catalog_with(catalog_translation_result([row])) do
      assert_equal 1, R::ForecastCatalogTranslation.translate([row])
    end
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

  def test_catalog_translation_keys_by_id_not_response_order_and_rejects_duplicates
    rows = [R::ForecastCatalog.entry(catalog_raw), R::ForecastCatalog.entry(catalog_raw.merge('id' => '902'))]
    data = JSON.parse(catalog_translation_result(rows))
    data['markets'].reverse!
    data['markets'].first['question'] = '第二个事件是否成立？'
    translated_catalog_with(data.to_json) { assert_equal 2, R::ForecastCatalogTranslation.translate(rows) }
    assert_equal '第二个事件是否成立？', R::ForecastCatalogTranslation.cached(rows.last)['question']
    data['markets'] << data['markets'].first.dup
    data['markets'].last['question'] = '重复编号不可覆盖'
    translated_catalog_with(data.to_json) { assert_equal 1, R::ForecastCatalogTranslation.translate(rows) }
    assert_equal '第二个事件是否成立？', R::ForecastCatalogTranslation.cached(rows.last)['question']
  end

  def test_catalog_translation_rejects_empty_english_and_truncated_response
    row = R::ForecastCatalog.entry(catalog_raw)
    ['bad', '{}', '{"markets":[]}', {markets: [{external_id:'901',question:'English',event_title:'Event',outcomes:['Yes','No']} ]}.to_json].each do |value|
      translated_catalog_with(value) { assert_equal 0, R::ForecastCatalogTranslation.translate([row]) }
    end
    refute R::ForecastCatalogTranslation.cached(row)
  end

  def test_catalog_translation_invalidates_changed_source_and_model
    row = R::ForecastCatalog.entry(catalog_raw)
    translated_catalog_with(catalog_translation_result([row])) { R::ForecastCatalogTranslation.translate([row]) }
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

  def test_preview_translation_queue_is_deduplicated_and_bounded
    original = R::ForecastTranslation.method(:enabled?)
    R::ForecastTranslation.define_singleton_method(:enabled?) { true }
    260.times do |i|
      market = R::ForecastMarket.new(R::ForecastProvider.parse(catalog_raw.merge('id' => (900+i).to_s)))
      assert R::ForecastTranslation.enqueue(market)
    end
    assert_equal 256, Discourse.redis.zcard(R::ForecastTranslation::PREVIEW_QUEUE)
    market = R::ForecastMarket.new(R::ForecastProvider.parse(catalog_raw))
    assert R::ForecastTranslation.enqueue(market)
    assert_equal 256, Discourse.redis.zcard(R::ForecastTranslation::PREVIEW_QUEUE)
    translated_with(translation_result) { assert R::ForecastTranslation.translate(market) }
    refute R::ForecastTranslation.enqueue(market)
  ensure
    R::ForecastTranslation.define_singleton_method(:enabled?, original)
  end
end
