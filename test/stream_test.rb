# frozen_string_literal: true
class StreamTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def ticker(at = Time.current, price = '100')
    {'type'=>'ticker', 'product_id'=>'BTC-USD', 'price'=>price, 'time'=>at.iso8601(6), 'best_bid'=>'99', 'best_ask'=>'101', 'open_24h'=>'90'}
  end

  def test_stream_validates_source_time_and_price
    now = Time.current
    data = R::CryptoStream.quote(ticker(now), received_at: now)
    assert_equal 'coinbase_ws', data['source']
    assert_equal now.iso8601(6), data['source_time']
    assert_nil R::CryptoStream.quote(ticker(now - 121), received_at: now)
    assert_nil R::CryptoStream.quote(ticker(now + 6), received_at: now)
    %w[0 -1 NaN Infinity invalid].each { |price| assert_nil R::CryptoStream.quote(ticker(now, price), received_at: now) }
    assert_nil R::CryptoStream.quote(ticker.merge('product_id'=>'BTC-EUR'))
    assert_nil R::CryptoStream.quote(ticker.merge('type'=>'heartbeat'))
  end

  def test_stream_prevents_quote_regression_and_bounds_history_frequency
    stock = instrument
    stock.update!(category: 'crypto', quote: {}, history: [])
    now = Time.current
    R::MarketData.record_quote(stock, R::CryptoStream.quote(ticker(now)), stream: true)
    R::MarketData.record_quote(stock, R::CryptoStream.quote(ticker(now - 1, '90')), stream: true)
    assert_equal '100.0', stock.reload.quote['price']
    R::MarketData.record_quote(stock, R::CryptoStream.quote(ticker(now + 1, '101')), stream: true)
    assert_equal '101.0', stock.reload.quote['price']
    assert_equal 1, stock.history.size
    newer = R::CryptoStream.quote(ticker(now + 61, '102'), received_at: now + 61)
    R::MarketData.record_quote(stock, newer, stream: true)
    assert_equal 2, stock.reload.history.size
    assert_equal 0, R::Journal.count
  end

  def test_stream_lease_cannot_be_renewed_or_deleted_by_old_owner
    key = 'rsc:test-stream:lease'
    Discourse.redis.set(key, 'new-owner', ex: 20)
    assert_equal 0, R::ProviderHttp.evaluate(R::CryptoStream::RENEW, keys: [key], argv: ['old-owner'])
    assert_equal 0, R::ProviderHttp.evaluate(R::CryptoStream::RELEASE, keys: [key], argv: ['old-owner'])
    assert_equal 'new-owner', Discourse.redis.get(key)
    assert_equal 1, R::ProviderHttp.evaluate(R::CryptoStream::RENEW, keys: [key], argv: ['new-owner'])
    assert_equal 1, R::ProviderHttp.evaluate(R::CryptoStream::RELEASE, keys: [key], argv: ['new-owner'])
  ensure
    Discourse.redis.del(key)
  end

  def test_trading_schedule_uses_quotes_without_waiting_for_http
    fund
    stock = instrument
    result = R::Exchange.submit(actor: @alice, instrument_id: stock.id, side: 'long', quantity: '1', leverage: 5, request_id: SecureRandom.uuid)
    fill(stock, R::Order.find(result['order_id']))
    stock.update!(quote: quote('70'))
    original = R::MarketData.method(:sync_crypto)
    R::MarketData.define_singleton_method(:sync_crypto) { |_| raise 'network work in scheduler' }
    Jobs::DiscourseRscTradingTick.new.execute({})
    refute R::Position.exists?(instrument_id: stock.id)
    assert R::Event.exists?(kind: 'stock_liquidated')
    assert Discourse.redis.get('rsc:trading:last_tick')
    assert_equal 0, R::Entry.sum(:units)
  ensure
    R::MarketData.define_singleton_method(:sync_crypto, original) if original
    Discourse.redis.del('rsc:provider-poll:crypto')
  end

  def test_stream_and_trading_respect_readonly
    SiteSetting.rsc_market_data_enabled = true
    SiteSetting.rsc_crypto_stream_enabled = true
    assert R::CryptoStream.enabled?
    SiteSetting.rsc_read_only = true
    refute R::CryptoStream.enabled?
    Discourse.redis.del('rsc:trading:last_tick', 'rsc:provider-poll:crypto')
    Jobs::DiscourseRscTradingTick.new.execute({})
    assert_nil Discourse.redis.get('rsc:trading:last_tick')
    assert_nil Discourse.redis.get('rsc:provider-poll:crypto')
  ensure
    SiteSetting.rsc_crypto_stream_enabled = false
  end
  def test_background_workers_do_not_overfill_shared_provider_queue
    SiteSetting.rsc_market_data_enabled = true
    host = 'query1.finance.yahoo.com'
    %w[next cooldown].each { |kind| Discourse.redis.del(R::ProviderHttp.key(host, kind)) }
    5.times { |n| R::Instrument.create!(symbol: "QUEUE#{n}", name: 'Queue test', category: 'us', provider: 'yahoo', quote: {}) }
    original = R::MarketData.method(:fetch_quote)
    fresh = quote('100')
    R::MarketData.define_singleton_method(:fetch_quote) do |item|
      R::ProviderHttp.pace!(host)
      fresh.deep_dup
    end
    results = R::MarketData.sync
    assert_equal 5, results.size
    assert results.values.all?
    assert_empty R::Instrument.where.not(provider_error: nil)
  ensure
    R::MarketData.define_singleton_method(:fetch_quote, original) if original
    %w[next cooldown].each { |kind| Discourse.redis.del(R::ProviderHttp.key(host, kind)) }
  end

end
