# frozen_string_literal: true
require '/rsc/test/business_test'
require '/rsc/test/completion_test'

class CatalogAutoListingTest < CompletionTest
  CompletionTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def setup
    super
    SiteSetting.rsc_market_data_enabled = true
  end

  def test_member_adds_supported_market_without_admin_or_reason_and_clears_catalog_cache
    Rails.cache.write('rsc:market:catalog:v1', [])
    legacy = R::MarketRequest.create!(user_id: @bob.id, symbol: 'AAPL')
    with_provider(JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))) do
      result = R::Catalog.request(actor: @alice, symbol: 'NASDAQ:AAPL')
      assert_equal 'approved', result['status']
      assert_equal 'AAPL', R::Instrument.find(result['instrument_id']).provider_symbol
      request = R::MarketRequest.find(result['id'])
      assert_equal 'approved', request.status
      assert_equal 1, request.details['request_count']
      assert_equal result['instrument_id'], request.details['instrument_id']
      assert_equal 'approved', legacy.reload.status
    end
    assert_nil Rails.cache.read('rsc:market:catalog:v1')
    assert_equal 1, R::Audit.where(action: 'market_auto_list', actor_user_id: @alice.id).count
    assert_equal 0, R::Order.count
    assert_equal 0, R::Journal.count
  end

  def test_existing_market_is_reused_without_provider_request_and_does_not_duplicate
    stock = instrument
    stock.update!(provider: 'yahoo', provider_symbol: 'AAPL')
    with_provider(->(*) { flunk 'Existing symbol must not contact upstream' }) do
      2.times do
        assert_equal stock.id, R::Catalog.request(actor: @alice, symbol: 'NASDAQ:AAPL')['instrument_id']
      end
      assert_equal stock.id, R::Catalog.request(actor: @bob, symbol: 'AAPL')['instrument_id']
    end
    assert_equal 1, R::Instrument.count
    assert_equal 2, R::MarketRequest.count
    assert_equal 2, R::MarketRequest.find_by!(user_id: @alice.id).details['request_count']
    assert R::MarketRequest.all.all? { |r| r.status == 'approved' }
  end

  def test_failed_lookup_is_retained_with_chinese_reason_and_can_be_retried
    with_provider(->(*) { raise R::Error.new('provider_no_data') }) do
      assert_equal 'provider_no_data', assert_raises(R::Error) { R::Catalog.request(actor: @alice, symbol: 'AAPL') }.code
    end
    request = R::MarketRequest.last
    assert_equal 'pending', request.status
    assert_equal 'provider_no_data', request.details['last_error_code']
    assert_match(/\p{Han}/, request.details['last_error'])
    assert_equal 0, R::Instrument.count
    with_provider(JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))) { R::Catalog.request(actor: @alice, symbol: 'AAPL') }
    assert_equal 'approved', request.reload.status
    refute request.details.key?('last_error')
    refute request.details.key?('last_error_code')
    assert_equal 1, R::MarketRequest.count
  end

  def test_inactive_symbol_cannot_be_reenabled_by_a_member
    stock = instrument
    stock.update!(provider_symbol: 'AAPL', active: false)
    with_provider(->(*) { flunk 'Inactive symbol must not contact upstream' }) do
      assert_equal 'instrument_inactive', assert_raises(R::Error) { R::Catalog.request(actor: @alice, symbol: 'AAPL') }.code
    end
    refute stock.reload.active?
    assert_equal 1, R::Instrument.count
  end

  def test_membership_read_only_and_unsupported_market_still_enforced
    outsider = make_user('rsc_outsider')
    assert_equal 'membership_required', assert_raises(R::Error) { R::Catalog.request(actor: outsider, symbol: 'AAPL') }.code
    SiteSetting.rsc_read_only = true
    assert_equal 'read_only', assert_raises(R::Error) { R::Catalog.request(actor: @alice, symbol: 'AAPL') }.code
    assert_equal 0, R::MarketRequest.count
    SiteSetting.rsc_read_only = false
    data = JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))
    data['chart']['result'][0]['meta'].merge!('symbol' => 'GC=F', 'instrumentType' => 'FUTURE')
    with_provider(data) do
      assert_equal 'invalid_symbol', assert_raises(R::Error) { R::Catalog.request(actor: @alice, symbol: 'GC=F') }.code
    end
    assert_equal 0, R::Instrument.count
  end

  def test_malformed_provider_response_returns_a_retryable_chinese_error
    data = JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))
    data['chart']['result'][0]['meta'].delete('regularMarketPrice')
    with_provider(data) do
      assert_equal 'provider_invalid_data', assert_raises(R::Error) { R::Catalog.request(actor: @alice, symbol: 'AAPL') }.code
    end
    assert_equal 'pending', R::MarketRequest.last.status
    assert_match(/\p{Han}/, R::MarketRequest.last.details['last_error'])
    assert_equal 0, R::Instrument.count
  end

  def test_admin_listing_reason_is_optional_but_admin_endpoint_is_not_public
    stock = instrument
    stock.update!(provider_symbol: 'AAPL')
    assert_equal stock.id, R::Catalog.approve(actor: @admin, symbol: 'AAPL', request_id: 'no-reason-needed')['instrument_id']
    assert_equal 'admin_required', assert_raises(R::Error) { R::Catalog.approve(actor: @alice, symbol: 'AAPL', request_id: 'not-an-admin') }.code
  end
end
