# frozen_string_literal: true
require_relative 'forecast_test'
class ForecastTest
  alias_method :forecast_base_setup, :setup
  def setup
    forecast_base_setup
    PluginStoreRow.where(plugin_name: R::ForecastTranslation::STORE).delete_all
    Rails.cache.clear
  end
  def translation_result
    { question: '演示会确认“是”吗？', event_title: '演示', rules: '合成测试：最终确认决定每份兑付。', outcomes: %w[是 否] }.to_json
  end
  def translated_with(result)
    original = R::ForecastTranslation.method(:generate)
    R::ForecastTranslation.define_singleton_method(:generate) { |_market| result }
    yield
  ensure
    R::ForecastTranslation.define_singleton_method(:generate, original)
  end
  def test_translation_cache_does_not_modify_terms_or_settlement
    original_terms = @market.terms_digest
    translated_with(translation_result) do
      assert R::ForecastTranslation.translate(@market)
      assert_equal '演示会确认“是”吗？', R::ForecastTranslation.presentation(@market)[:question]
      assert_equal %w[是 否], R::ForecastTranslation.presentation(@market)[:outcomes]
      assert_equal original_terms, @market.reload.terms_digest
      assert_equal @raw['description'], @market.rules
      execute(quote)
      confirm_resolution
      assert_equal 1, R::ForecastSettlement.settle(@market)
    end
  end
  def test_translation_rejects_malformed_and_truncated_output
    ['not json', '{}', '{"question":"翻译"}', translation_result.sub('合成测试：最终确认决定每份兑付。', '')].each do |bad|
      translated_with(bad) { refute R::ForecastTranslation.translate(@market) }
    end
    refute R::ForecastTranslation.presentation(@market)[:translated]
    assert_equal @raw['question'], R::ForecastTranslation.presentation(@market)[:question]
  end
  def test_translation_invalidated_when_source_changes
    translated_with(translation_result) { assert R::ForecastTranslation.translate(@market) }
    @market.update!(terms_digest: 'changed')
    refute R::ForecastTranslation.cached(@market)
    assert_equal @raw['question'], R::ForecastTranslation.presentation(@market)[:question]
  end
  def test_translation_reads_do_not_call_provider
    # No AI plugin or credentials are required for isolated unit coverage.
    original = R::ForecastTranslation.method(:generate)
    calls = 0
    R::ForecastTranslation.define_singleton_method(:generate) { |_m| calls += 1; translation_result }
    # Cache serves reads without any synchronous model calls.
    3.times { R::ForecastTranslation.presentation(@market) }
    assert_equal 0, calls
  ensure
    R::ForecastTranslation.define_singleton_method(:generate, original)
  end
  def test_previous_chinese_stays_visible_while_refresh_is_pending
    old=JSON.parse(translation_result).merge('signature'=>R::ForecastTranslation.signature(@market,version:1))
    PluginStore.set(R::ForecastTranslation::STORE,@market.id.to_s,old)
    assert R::ForecastTranslation.cached(@market)
    refute R::ForecastTranslation.cached(@market,fresh:true)
    assert_equal '演示会确认“是”吗？',R::ForecastTranslation.presentation(@market)[:question]
    translated_with(translation_result) { assert R::ForecastTranslation.translate(@market) }
    assert R::ForecastTranslation.cached(@market,fresh:true)
    @market.update!(terms_digest:'new terms')
    refute R::ForecastTranslation.cached(@market)
  end
  def test_model_change_invalidates_new_translation
    previous=SiteSetting.rsc_forecast_translation_model_id
    translated_with(translation_result) { assert R::ForecastTranslation.translate(@market) }
    SiteSetting.rsc_forecast_translation_model_id=previous+1
    refute R::ForecastTranslation.cached(@market,fresh:true)
  ensure
    SiteSetting.rsc_forecast_translation_model_id=previous
  end

  def test_neutral_input_expands_only_explicit_contract_definition
    @market.question = 'Will Country A invade Country B before 2027?'
    @market.event_title = @market.question
    @market.rules = 'Yes if a military offensive intended to establish control over any portion of Country B commences.'
    source = R::ForecastTranslation.translation_source(@market)
    assert_includes source['question'], 'intended to establish control over any part of Country B before 2027?'
    assert_includes @market.question, 'invade'
    assert_equal @market.rules, source['rules']
    @market.rules = 'Yes if any attack occurs.'
    assert_equal @market.question, R::ForecastTranslation.translation_source(@market)['question']
  end

  def test_loaded_headline_is_not_cached_for_explicit_control_contract
    @market.update!(question: 'Will A invade B?', event_title: 'Will A invade B?',
      rules: 'A military offensive intended to establish control over any portion of B.')
    bad = JSON.parse(translation_result).merge('question' => 'A 会入侵 B 吗？').to_json
    translated_with(bad) { refute R::ForecastTranslation.translate(@market) }
    refute R::ForecastTranslation.cached(@market)
  end

end
