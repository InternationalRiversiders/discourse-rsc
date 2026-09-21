# frozen_string_literal: true
class RequestReviewTest < FinalReviewTest
  FinalReviewTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }
  HOST = 'query1.finance.yahoo.com'

  def archive(table, row)
    R::LegacyRecord.create!(source_table: table, source_id: row.fetch(:id).to_s, data: row)
  end

  def setup
    super
    R::ProviderHttp::HOSTS.each { |host| %w[next cooldown].each { |kind| Discourse.redis.del(R::ProviderHttp.key(host, kind)) } }
  end

  def teardown
    R::ProviderHttp::HOSTS.each { |host| %w[next cooldown].each { |kind| Discourse.redis.del(R::ProviderHttp.key(host, kind)) } }
    super
  end

  def with_http(code: '200', retry_after: nil, failure: nil)
    original = Net::HTTP.method(:start)
    calls = []
    response = Object.new
    response.define_singleton_method(:code) { code }
    response.define_singleton_method(:[]) { |_| retry_after }
    response.define_singleton_method(:read_body) { |&block| block.call('{"ok":true}') }
    client = Object.new
    client.define_singleton_method(:request) { |request, &block| calls << request; raise failure if failure; block.call(response) }
    Net::HTTP.define_singleton_method(:start) { |*args, **kwargs, &block| block.call(client) }
    yield calls
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_provider_slots_are_shared_between_processes_and_queue_is_bounded
    results = 7.times.map do
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(R::ProviderHttp.reserve(HOST).to_s)
        writer.close
        exit! 0
      end
      writer.close
      value = Integer(reader.read)
      reader.close
      Process.wait(pid)
      assert $?.success?
      value
    end
    accepted = results.select { |n| n >= 0 }
    assert_equal 4, accepted.size
    assert_equal 3, results.count(-2)
    assert_operator accepted.last, :>=, 2500
    assert_operator accepted.last, :<=, 3000
  end

  def test_429_cools_all_paths_symbols_and_processes_without_retrying_http
    with_http(code: '429') do |calls|
      assert_equal 'provider_http_429', assert_raises(R::Error) { R::ProviderHttp.get(HOST, '/quote-a') }.code
      assert_operator Discourse.redis.ttl(R::ProviderHttp.key(HOST, 'cooldown')), :>=, 899
      assert_equal 'provider_cooldown', assert_raises(R::Error) { R::ProviderHttp.get(HOST, '/search-b') }.code
      reader, writer = IO.pipe
      pid = fork { reader.close; writer.write(R::ProviderHttp.reserve(HOST).to_s); writer.close; exit! 0 }
      writer.close
      assert_equal '-1', reader.read
      reader.close; Process.wait(pid)
      assert_equal 1, calls.size
      assert_equal 'close', calls.first['Connection']
      assert_operator R::ProviderHttp.reserve('site.api.espn.com'), :>=, 0
    end
  end

  def test_retry_after_and_failures_never_shorten_existing_provider_cooldown
    with_http(code: '429', retry_after: '1800') do
      assert_raises(R::Error) { R::ProviderHttp.get(HOST, '/quote') }
      R::ProviderHttp.cooldown(HOST, 120)
      assert_operator Discourse.redis.ttl(R::ProviderHttp.key(HOST, 'cooldown')), :>=, 1799
    end
    assert_in_delta 1800, R::ProviderHttp.retry_after((Time.now + 1800).httpdate), 2
    assert_equal 900, R::ProviderHttp.retry_after('invalid')
  end

  def test_network_and_server_failures_cool_for_two_minutes
    [Net::ReadTimeout.new, nil].each do |failure|
      Discourse.redis.del(R::ProviderHttp.key(HOST, 'cooldown'), R::ProviderHttp.key(HOST, 'next'))
      with_http(code: '503', failure: failure) do |calls|
        assert_raises(R::Error) { R::ProviderHttp.get(HOST, '/quote') }
        assert_operator Discourse.redis.ttl(R::ProviderHttp.key(HOST, 'cooldown')), :>=, 119
        assert_equal 'provider_cooldown', assert_raises(R::Error) { R::ProviderHttp.get(HOST, '/other') }.code
        assert_equal 1, calls.size
      end
    end
  end

  def test_read_trade_delayed_and_idle_caches_have_separate_budgets
    item = stale_stock
    item.update!(quote: quote('100').merge('received_at' => 40.seconds.ago.iso8601))
    refute R::MarketData.refresh_due?(item)
    assert R::MarketData.refresh_due?(item, purpose: :trade)
    refute R::MarketData.refresh_due?(item, purpose: :background)
    item.update!(quote: quote('100').merge('received_at' => 100.seconds.ago.iso8601))
    refute R::MarketData.refresh_due?(item)
    item.update!(quote: item.quote.merge('delay_seconds' => 600))
    assert R::MarketData.refresh_due?(item)
    refute R::MarketData.refresh_due?(item, purpose: :idle)
    item.update!(quote: quote('100').merge('received_at' => 121.seconds.ago.iso8601))
    assert R::MarketData.refresh_due?(item)
  end

  def test_background_and_concurrent_reads_share_one_fetch
    item = stale_stock
    with_quote_fetcher do |calls|
      Array.new(3) do
        Thread.new do
          Rails.application.executor.wrap do
            ActiveRecord::Base.connection_pool.with_connection { R::MarketData.refresh_if_needed(item.id) }
          end
        end
      end.each(&:value)
      R::MarketData.sync
      assert_equal [item.id], calls
    end
    assert_equal 0, R::Journal.count
  end

  def test_lunch_weekend_dst_and_fx_sessions_retain_legacy_rules
    item = stale_stock
    archive('market_instruments', {id: 900, symbol: item.symbol, trading_hours: '09:30-11:30,13:00-15:00 Asia/Shanghai'})
    assert R::MarketSessions.closed?(item, Time.utc(2026,9,21,3,45))
    refute R::MarketSessions.closed?(item, Time.utc(2026,9,21,5,15))
    assert R::MarketSessions.closed?(item, Time.utc(2026,9,20,5,15))
    record = R::LegacyRecord.find_by!(source_table: 'market_instruments')
    record.update!(data: record.data.merge('trading_hours' => '09:30-16:00 America/New_York'))
    Discourse.cache.delete('rsc:trading-hours')
    refute R::MarketSessions.closed?(item, Time.utc(2026,9,21,13,45))
    assert R::MarketSessions.closed?(item, Time.utc(2026,1,20,13,45))
    refute R::MarketSessions.closed?(item, Time.utc(2026,1,20,14,45))
    item.category = 'forex'
    assert R::MarketSessions.closed?(item, Time.utc(2026,9,20,20,59))
    refute R::MarketSessions.closed?(item, Time.utc(2026,9,20,21))
  end

  def test_closed_local_session_skips_provider_and_rejects_otherwise_fresh_price
    item = stale_stock
    local = Time.current.in_time_zone('Asia/Shanghai')
    # Pick a one-minute session outside the present minute, on any test date.
    minute = (local.hour * 60 + local.min + 60) % (24 * 60 - 1)
    start = format('%02d:%02d', minute / 60, minute % 60)
    finish = format('%02d:%02d', (minute + 1) / 60, (minute + 1) % 60)
    archive('market_instruments', {id: 901, symbol: item.symbol, trading_hours: "#{start}-#{finish} Asia/Shanghai"})
    with_quote_fetcher do |calls|
      R::MarketData.refresh_if_needed(item.id)
      assert_empty calls
      item.update!(quote: quote('100'))
      assert_equal 'market_closed', assert_raises(R::Error) { R::Exchange.price!(item, trading: true) }.code
      assert R::MarketListing.rows([item]).first[:market_closed]
    end
  end

  def test_quote_failure_preserves_old_price_and_does_not_retry_for_two_minutes
    item = stale_stock
    with_http(code: '429') do |calls|
      R::MarketData.refresh_if_needed(item.id)
      item.reload.update!(synced_at: 90.seconds.ago)
      R::MarketData.refresh_if_needed(item.id, purpose: :trade)
      assert_equal 1, calls.size
      assert_equal 'quote_stale', assert_raises(R::Error) { R::Exchange.price!(item.reload) }.code
      assert_equal 0, R::Journal.count
    end
  end
  def test_intraday_chart_recovers_cached_data_on_provider_failure_without_retimestamping
    item = stale_stock
    candles = [{ 'at' => 10.minutes.ago.iso8601, 'close' => '99' }, { 'at' => 9.minutes.ago.iso8601, 'close' => '100' }]
    cache = R::HistoryCache.create!(instrument_id: item.id, range: '1d', currency: 'USD', source: 'provider', candles: candles, updated_at: 3.minutes.ago)
    previous = cache.updated_at
    with_http(code: '429') do |calls|
      data = R::MarketData.history(item, '1d')
      assert data[:stale]
      assert_equal candles, data[:candles]
      assert_equal 'provider_http_429', data[:refresh_error]
      assert_equal previous, cache.reload.updated_at
      again = R::MarketData.history(item, '1d')
      assert again[:stale]
      assert_equal 1, calls.size
    end
    assert_equal 'quote_stale', assert_raises(R::Error) { R::Exchange.price!(item.reload) }.code
  end

  def test_protection_refreshes_price_outside_transaction_and_replay_does_not_fetch
    fund
    item = instrument
    R::Exchange.submit(actor: @alice, instrument_id: item.id, side: 'long', quantity: '1', leverage: 1, request_id: 'position-to-protect')
    position = R::Position.find_by!(instrument_id: item.id)
    item.update!(provider: 'yahoo', quote: quote('100').merge('received_at' => 5.minutes.ago.iso8601))
    SiteSetting.rsc_market_data_enabled = true
    with_quote_fetcher do |calls|
      args = {actor: @alice, position_id: position.id, take_profit: '110', stop_loss: nil, request_id: 'protect-fresh'}
      R::Exchange.protect(**args)
      assert R::Exchange.protect(**args)['replayed']
      assert_equal [item.id], calls
    end
  end

  def test_failed_http_order_keeps_diagnostic_audit_without_creating_money_or_trade
    item = instrument
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host!('rsc.test'); session.https!
    key = ApiKey.create!(user_id: @alice.id, created_by_id: @admin.id, description: 'isolated rejection review')
    session.post '/rsc/orders.json', headers: {'Api-Key' => key.key, 'Api-Username' => @alice.username}, params: {
      instrument_id: item.id, side: 'long', quantity: '0', leverage: 1, request_id: 'invalid-quantity-review'
    }
    assert_equal 422, session.response.status
    audit = R::Audit.find_by!(action: 'order_rejected')
    assert_equal @alice.id, audit.actor_user_id
    assert_equal JSON.parse(session.response.body)['error_code'], audit.details['error']
    assert_equal 'invalid-quantity-review', audit.details['request_id']
    assert_equal 0, R::Journal.count
    assert_equal 0, R::Order.count
  ensure
    key&.destroy!
  end

  def test_admin_market_category_filter_applies_before_pagination
    a = instrument
    R::Instrument.create!(symbol: 'HK-DEMO', name: 'Hong Kong demo', category: 'hk')
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host!('rsc.test'); session.https!
    key = ApiKey.create!(user_id: @admin.id, created_by_id: @admin.id, description: 'isolated category review')
    headers = {'Api-Key' => key.key, 'Api-Username' => @admin.username}
    session.get '/rsc/admin/state.json', headers: headers, params: {instrument_category: 'hk'}
    assert_equal 200, session.response.status
    body = JSON.parse(session.response.body)
    assert_equal ['HK-DEMO'], body['instruments'].map { |row| row['symbol'] }
    assert_equal 1, body.dig('pagination', 'instrument', 'total')
    session.get '/rsc/admin/state.json', headers: headers, params: {instrument_category: 'invalid'}
    assert_equal 422, session.response.status
  ensure
    key&.destroy!
  end

end
