# frozen_string_literal: true
require_relative 'forecast_test'

class ForecastTest
  def test_forecast_error_extreme_buy_price_is_not_a_depth_error
    %w[0.005 0.995].each do |price|
      @asks = [{ 'price' => price, 'size' => '1000000' }]
      %w[1 10 351].each do |amount|
        assert_equal 'forecast_probability_range', assert_raises(R::Error) { quote('buy', amount) }.code
      end
    end
    assert_equal '100', R::Account.wallet(@alice.id).balance
    assert_equal 0, R::ForecastQuote.count
    assert_equal 0, R::ForecastTrade.count
  end

  def test_forecast_error_boundary_prices_and_extreme_sell_remain_allowed
    %w[0.02 0.98].each do |price|
      book = { 'asks' => [{ 'price' => price, 'size' => '1000' }] }
      shares, cash = R::ForecastExchange.fill(book, 'buy', R::Amount.parse('1'))
      assert_operator shares, :>, 0
      assert_operator cash, :<=, R::Amount.parse('1')
    end
    %w[0.005 0.995].each do |price|
      book = { 'bids' => [{ 'price' => price, 'size' => '1000' }] }
      shares, cash = R::ForecastExchange.fill(book, 'sell', R::Amount.parse('10'))
      assert_equal R::Amount.parse('10'), shares
      assert_operator cash, :>, 0
    end
    assert_equal 'forecast_liquidity', assert_raises(R::Error) { R::ForecastExchange.fill({ 'asks' => [] }, 'buy', R::Amount.parse('1')) }.code
  end

  def forecast_book_fixture(age: 0, asset: '123', timestamp: nil)
    { 'market' => @market.condition_id, 'asset_id' => asset,
      'timestamp' => timestamp || ((Time.current.to_f - age) * 1000).to_i.to_s,
      'asks' => @asks, 'bids' => @bids }
  end

  def with_forecast_books(*books)
    original = R::ForecastProvider.method(:get)
    calls = []
    R::ForecastProvider.define_singleton_method(:get) do |*args|
      calls << args
      item = books.fetch(calls.size - 1)
      raise item if item.is_a?(Exception)
      item
    end
    yield calls
  ensure
    R::ForecastProvider.define_singleton_method(:get, original)
  end

  def test_forecast_error_stale_read_retries_once_and_accepts_fresh_book
    fresh = forecast_book_fixture
    with_forecast_books(forecast_book_fixture(age: 120), fresh) do |calls|
      assert_equal fresh, R::ForecastProvider.book(@market, 0)
      assert_equal 2, calls.size
      assert_equal calls.first, calls.last
    end
  end

  def test_forecast_error_repeated_stale_book_stops_without_a_third_read
    with_forecast_books(*Array.new(2) { forecast_book_fixture(age: 120) }) do |calls|
      assert_equal 'forecast_stale', assert_raises(R::Error) { R::ForecastProvider.book(@market, 0) }.code
      assert_equal 2, calls.size
    end
    assert_equal 0, R::ForecastTrade.count
    assert_equal '100', R::Account.wallet(@alice.id).balance
  end

  def test_forecast_error_wrong_asset_invalid_time_and_future_time_never_retry
    [forecast_book_fixture(asset: 'wrong'), forecast_book_fixture(timestamp: 'invalid'), forecast_book_fixture(age: -60)].each do |book|
      with_forecast_books(book) do |calls|
        assert_raises(R::Error) { R::ForecastProvider.book(@market, 0) }
        assert_equal 1, calls.size
      end
    end
  end

  def test_forecast_error_second_read_validates_identity_and_respects_provider_failure
    [forecast_book_fixture(asset: 'wrong'), R::Error.new('provider_cooldown', status: 503)].each do |second|
      with_forecast_books(forecast_book_fixture(age: 120), second) do |calls|
        assert_raises(R::Error) { R::ForecastProvider.book(@market, 0) }
        assert_equal 2, calls.size
      end
    end
  end

  def test_forecast_error_fresh_book_uses_one_request
    with_forecast_books(forecast_book_fixture) do |calls|
      R::ForecastProvider.book(@market, 0)
      assert_equal 1, calls.size
    end
  end
end
