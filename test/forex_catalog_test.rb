# frozen_string_literal: true
require '/rsc/test/forex_precision_test'

class ForexCatalogTest < ForexPrecisionTest
  ForexPrecisionTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def test_local_search_matches_country_currency_code_and_old_provider_alias
    item = forex
    item.update!(symbol: 'FX:BRL', name: 'Brazilian Real', provider_symbol: 'BRLUSD=X')
    instrument # Keep a real stock category available while testing FX filtering.
    %w[巴西 雷亚尔 BRL brl BRL/USD USD/BRL].each do |query|
      page = R::MarketListing.page(market_category: 'forex', market_search: query)
      assert_equal [item.id], page[:rows].map { |row| row[:id] }, query
      assert_equal '巴西雷亚尔', page[:rows].first[:currency_name]
    end
    assert_empty R::MarketListing.page(market_category: 'us', market_search: '巴西')[:rows]
    item.update!(symbol: 'BRL=X', provider_symbol: 'BRL=X')
    assert_equal '巴西雷亚尔', R::ForexActivity.currency_name(item)
  end

  def test_explicit_fx_discovery_does_not_depend_on_yahoo_search
    with_provider(->(*) { flunk 'Known FX lookup must be local' }) do
      %w[巴西 BRL BRL/USD USD/BRL 雷亚尔 日本 日元 泰国 泰铢].each do |query|
        assert_equal 1, R::MarketData.search(query).size, query
      end
      assert_equal 'BRL=X', R::MarketData.search('巴西').first[:symbol]
      assert_equal '巴西雷亚尔', R::MarketData.search('BRL').first[:name]
    end
    assert_equal 'invalid_search', assert_raises(R::Error) { R::MarketData.search('') }.code
  end

  def test_general_search_keeps_stock_results
    Discourse.cache.delete("rsc:search:#{Digest::SHA256.hexdigest('Brazil')}")
    response = { 'quotes'=>[{ 'symbol'=>'EWZ', 'quoteType'=>'ETF', 'shortname'=>'Brazil ETF' }] }
    with_provider(response) do
      assert_equal %w[BRL=X EWZ], R::MarketData.search('Brazil').map { |row| row[:symbol] }
    end
  ensure
    Discourse.cache.delete("rsc:search:#{Digest::SHA256.hexdigest('Brazil')}")
  end

  def test_approval_aliases_use_one_fx_market_and_reciprocal_price
    data = chart('5')
    data['chart']['result'][0]['meta'].merge!('symbol'=>'BRL=X', 'currency'=>'BRL', 'instrumentType'=>'CURRENCY')
    SiteSetting.rsc_market_data_enabled = true
    with_provider(data) do
      result = R::Catalog.approve(actor: @admin, symbol: 'BRL=X', reason: 'add Brazilian real', request_id: SecureRandom.uuid)
      item = R::Instrument.find(result['instrument_id'])
      assert_equal 'FX:BRL', item.symbol
      assert_equal '巴西雷亚尔', item.name
      assert_equal 'USD', item.currency
      assert_equal '0.2', item.quote['price']
      assert_equal 'BRL', item.quote['base_currency']
      assert_equal item.id, R::Catalog.approve(actor: @admin, symbol: 'FX:BRL', request_id: SecureRandom.uuid)['instrument_id']
      item.update!(symbol: 'BRL=X') # Previously approved external symbol.
      assert_equal item.id, R::Catalog.approve(actor: @admin, symbol: 'FX:BRL', request_id: SecureRandom.uuid)['instrument_id']
      assert_equal 1, R::Instrument.count
    end
    refute R::Catalog.respond_to?(:seed)
    refute R::Instrument.exists?(symbol: 'FX:MXN')
  end
end
