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
end
