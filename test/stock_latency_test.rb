# frozen_string_literal: true
require '/rsc/test/business_test'
require 'active_support/testing/time_helpers'

class StockLatencyTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }
  include ActiveSupport::Testing::TimeHelpers

  def replace_method(owner, name, replacement)
    original = owner.method(name)
    owner.define_singleton_method(name, replacement)
    yield
  ensure
    owner.define_singleton_method(name, original)
  end

  def cn
    item = instrument
    item.update!(category: 'cn', provider: 'yahoo', metadata: { 'trading_hours' => '09:30-11:30,13:00-15:00 Asia/Shanghai' })
    update_cn_quote(item)
    item
  end

  def update_cn_quote(item, source: 15.minutes.ago)
    item.update!(quote: quote('100').merge('source' => 'yahoo', 'delay_seconds' => 900,
      'source_time' => source.iso8601(6), 'session_start' => Time.utc(2026, 11, 2, 1, 30).iso8601,
      'session_end' => Time.utc(2026, 11, 2, 7).iso8601), synced_at: Time.current)
  end

  def open_order(item)
    result = R::Exchange.submit(actor: @alice, instrument_id: item.id, side: 'long', quantity: '1', leverage: 5, request_id: SecureRandom.uuid)
    R::Order.find(result['order_id'])
  end

  def test_stock_valid_quote_never_fetches_on_submit
    travel_to(Time.utc(2026, 11, 2, 3, 20)) do
      item = cn
      SiteSetting.rsc_market_data_enabled = true
      replace_method(R::MarketData, :sync_one, ->(*) { flunk 'Unexpected provider refresh' }) do
        assert_equal item.id, R::MarketData.refresh_if_needed(item.id, purpose: :trade).id
        assert_equal item.id, R::MarketData.refresh_if_needed(item.id, purpose: :exit).id
      end
    end
  end

  def test_stock_lunch_settles_existing_order_but_blocks_new_orders
    travel_to(Time.utc(2026, 11, 2, 3, 20)) do
      fund; item = cn; order = open_order(item)
      travel 16.minutes
      update_cn_quote(item)
      assert R::MarketSessions.closed?(item)
      assert R::MarketSessions.delayed_settlement?(item)
      assert_equal 'order_pending', assert_raises(R::Error) { open_order(item) }.code
      R::Exchange.process(item.id)
      assert_equal 'market_closed', assert_raises(R::Error) { open_order(item) }.code
      assert_equal 'filled', order.reload.status
      assert_equal 1, R::Position.count
      assert_equal 0, R::Entry.sum(:units)
    end
  end

  def test_stock_lunch_does_not_fill_on_preorder_or_stale_quotes
    travel_to(Time.utc(2026, 11, 2, 3, 20)) do
      fund; item = cn; order = open_order(item)
      travel 11.minutes
      update_cn_quote(item)
      R::Exchange.process(item.id)
      assert_equal 'pending', order.reload.status
      travel 6.minutes
      item.update!(quote: item.quote.merge('received_at' => Time.current.iso8601))
      R::Exchange.process(item.id)
      assert_equal 'pending', order.reload.status
      assert_equal 0, R::Position.count
    end
  end

  def test_stock_lunch_preserves_existing_stop_loss_before_pending_open
    travel_to(Time.utc(2026, 11, 2, 3)) do
      fund; item = cn; first = open_order(item)
      travel 16.minutes
      update_cn_quote(item)
      R::Exchange.process(item.id)
      assert_equal 'filled', first.reload.status
      R::Position.first.update!(stop_loss_units: R::Amount.parse('95'))
      travel 4.minutes
      update_cn_quote(item)
      second = open_order(item)
      travel 16.minutes
      update_cn_quote(item)
      item.update!(quote: item.quote.merge('price' => '94'))
      R::Exchange.process(item.id)
      assert_equal 'canceled', second.reload.status
      assert_equal 0, R::Position.sum(:quantity_units)
      assert_equal 1, R::Journal.where(operation: 'stock_close').where("metadata->>'reason' = ?", 'stock_stop_loss').count
      assert_equal 0, R::Entry.sum(:units)
    end
  end

  def test_stock_eligible_quote_does_not_wait_for_estimated_timer
    travel_to(Time.utc(2026, 11, 2, 3, 10)) do
      fund; item = cn; order = open_order(item)
      travel 1.minute
      update_cn_quote(item, source: Time.current)
      assert_operator order.execute_at, :>, Time.current
      R::Exchange.process(item.id)
      assert_equal 'filled', order.reload.status
    end
  end

  def test_stock_delayed_close_print_can_settle_existing_order
    travel_to(Time.utc(2026, 11, 2, 6, 50)) do
      fund; item = cn; order = open_order(item)
      travel 16.minutes
      update_cn_quote(item)
      R::Exchange.process(item.id)
      assert_equal 'filled', order.reload.status
      assert_equal 'market_closed', assert_raises(R::Error) { R::Exchange.price!(item, trading: true) }.code
    end
  end

  def test_stock_late_closing_print_retains_measured_delay_without_reopening
    travel_to(Time.utc(2026, 11, 2, 7, 16)) do
      item = cn
      previous = item.quote.merge('delay_inferred' => true)
      incoming = previous.merge('source_time' => Time.utc(2026, 11, 2, 7).iso8601,
        'delay_seconds' => 0, 'delay_reported' => false).except('delay_inferred')
      observed = R::MarketData.observe_delay(previous, incoming, category: 'cn')
      assert_equal 900, observed['delay_seconds']
      item.update!(quote: observed)
      assert R::MarketSessions.delayed_settlement?(item)
      assert_equal 'market_closed', assert_raises(R::Error) { R::Exchange.price!(item, trading: true) }.code
      travel 5.minutes
      assert_equal 'quote_stale', assert_raises(R::Error) { R::Exchange.price!(item) }.code
    end
  end

  def test_measured_delay_survives_sparse_refresh_and_jitter_without_growing
    travel_to(Time.utc(2026, 11, 2, 3, 10)) do
      item = cn
      previous = item.quote.merge('delay_inferred' => true, 'delay_observations' => [])
      travel 11.minutes
      incoming = item.quote.merge('delay_seconds' => 0, 'delay_reported' => false,
        'received_at' => Time.current.iso8601, 'source_time' => 913.seconds.ago.iso8601)
      observed = R::MarketData.observe_delay(previous, incoming, category: 'cn')
      assert observed['delay_inferred']
      assert_equal 900, observed['delay_seconds']
      item.update!(quote: observed)
      assert_equal R::Amount.parse('100'), R::Exchange.price!(item, trading: true)
      travel 3.minutes
      frozen = R::MarketData.observe_delay(observed, incoming.merge('received_at' => Time.current.iso8601), category: 'cn')
      assert_equal 900, frozen['delay_seconds']
      item.update!(quote: frozen)
      assert_equal 'quote_stale', assert_raises(R::Error) { R::Exchange.price!(item, trading: true) }.code
    end
  end

  def test_measured_delay_clears_for_live_reported_or_new_session_quotes
    travel_to(Time.utc(2026, 11, 2, 3, 10)) do
      previous = cn.quote.merge('delay_inferred' => true)
      raw = previous.except('delay_inferred').merge('delay_seconds' => 0, 'delay_reported' => false)
      live = R::MarketData.observe_delay(previous, raw.merge('source_time' => 20.seconds.ago.iso8601), category: 'cn')
      assert_equal 0, live['delay_seconds']
      refute live['delay_inferred']
      reported = R::MarketData.observe_delay(previous, raw.merge('delay_reported' => true), category: 'cn')
      assert_equal 0, reported['delay_seconds']
      next_day = raw.merge('source_time' => (1.day.from_now - 900).iso8601,
        'received_at' => 1.day.from_now.iso8601,
        'session_start' => (Time.iso8601(raw['session_start']) + 1.day).iso8601,
        'session_end' => (Time.iso8601(raw['session_end']) + 1.day).iso8601)
      assert_equal 0, R::MarketData.observe_delay(previous, next_day, category: 'cn')['delay_seconds']
    end
  end

  def test_stock_pending_lunch_refresh_without_catalog_polling
    travel_to(Time.utc(2026, 11, 2, 3, 20)) do
      fund; item = cn; order = open_order(item)
      travel 16.minutes
      refute R::MarketData.refresh_due?(item, purpose: :idle)
      assert R::MarketData.refresh_due?(item, purpose: :execution)
      R::Exchange.cancel(actor: @alice, order_id: order.id, request_id: SecureRandom.uuid)
      refute R::MarketData.refresh_due?(item, purpose: :execution)
    end
  end

  def test_stock_pending_refresh_precedes_older_held_symbol_and_calls_execution
    travel_to(Time.utc(2026, 11, 2, 3, 20)) do
      fund
      held = instrument
      held.update!(symbol: 'HELD', provider: 'yahoo', synced_at: 1.hour.ago)
      open_order(held)
      pending = cn
      open_order(pending)
      travel 1.minute
      SiteSetting.rsc_market_data_enabled = true
      SiteSetting.rsc_market_sync_batch = 1
      refreshed = []; processed = []
      replace_method(R::MarketData, :refresh_if_needed, ->(id, purpose:) {
        refreshed << [id, purpose]
        R::Instrument.find(id)
      }) do
        R::MarketData.sync { |id| processed << id }
      end
      assert_equal [[pending.id, :execution]], refreshed
      assert_equal [pending.id], processed
    ensure
      SiteSetting.rsc_market_sync_batch = 100
    end
  end

  def with_backup
    travel_to(Time.utc(2026, 11, 2, 15)) do
      SiteSetting.rsc_twelve_data_api_key = 'isolated'
      SiteSetting.rsc_us_stock_fallback_enabled = true
      item = instrument
      item.update!(symbol: 'NASDAQ:AAPL', provider: 'yahoo', provider_symbol: 'AAPL')
      Discourse.cache.delete('rsc:us-fallback:v1:AAPL')
      Discourse.redis.del('rsc:us-fallback:retry:AAPL', 'rsc:fx-fallback:slot', "rsc:fx-fallback:requests:#{Time.current.utc.to_date}")
      R::FallbackBudget.with_context(:trade) { yield item }
    ensure
      SiteSetting.rsc_twelve_data_api_key = ''
      SiteSetting.rsc_us_stock_fallback_enabled = false
    end
  end

  def test_stock_backup_is_minute_sampled_cached_and_shares_fx_quota
    with_backup do |item|
      old = item.quote.merge('source_time' => 10.minutes.ago.iso8601)
      calls = []
      replace_method(R::ProviderHttp, :get, ->(host, path, params) {
        calls << params
        { 'symbol' => 'AAPL', 'currency' => 'USD', 'close' => '100', 'timestamp' => 30.seconds.ago.to_i, 'is_market_open' => true }
      }) do
        first = R::MarketData.execution_quote(item, old)
        assert_equal 'twelve_data', first['source']
        assert_equal 0, first['delay_seconds']
        assert_equal '1min', calls.first[:interval]
        assert_equal first, R::MarketData.execution_quote(item, old)
        assert_equal 1, calls.size
        assert_equal '1', Discourse.redis.get("rsc:fx-fallback:requests:#{Time.current.utc.to_date}")
        item.update!(quote: first)
        assert_equal R::Amount.parse('100'), R::Exchange.price!(item, trading: true)
      end
    end
  end

  def test_stock_backup_skips_fresh_primary_and_exhausted_quota
    with_backup do |item|
      replace_method(R::ProviderHttp, :get, ->(*) { flunk 'Unexpected backup request' }) do
        fresh = item.quote.merge('source' => 'yahoo')
        assert_equal fresh, R::MarketData.execution_quote(item, fresh)
        Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}", '750')
        stale = fresh.merge('source_time' => 10.minutes.ago.iso8601)
        assert_equal stale, R::MarketData.execution_quote(item, stale)
      end
    end
  end

  def test_stock_backup_bad_timestamp_keeps_primary_and_backs_off
    with_backup do |item|
      stale = item.quote.merge('source_time' => 10.minutes.ago.iso8601)
      calls = 0
      replace_method(R::ProviderHttp, :get, ->(*) {
        calls += 1
        { 'symbol' => 'AAPL', 'currency' => 'USD', 'close' => '100', 'timestamp' => 10.minutes.ago.to_i, 'is_market_open' => true }
      }) do
        assert_equal stale, R::MarketData.execution_quote(item, stale)
        travel 9.seconds
        assert_equal stale, R::MarketData.execution_quote(item, stale)
        assert_equal 1, calls
      end
    end
  end

  def test_stock_backup_rejects_wrong_instrument_currency_or_closed_market
    with_backup do |item|
      stale = item.quote.merge('source_time' => 10.minutes.ago.iso8601)
      [{'symbol' => 'MSFT'}, {'currency' => 'CNY'}, {'is_market_open' => false}, {'timestamp' => 1.minute.from_now.to_i}].each do |override|
        Discourse.redis.del('rsc:fx-fallback:slot', 'rsc:us-fallback:retry:AAPL')
        data = { 'symbol' => 'AAPL', 'currency' => 'USD', 'close' => '100', 'timestamp' => Time.current.to_i, 'is_market_open' => true }.merge(override)
        replace_method(R::ProviderHttp, :get, ->(*) { data }) do
          assert_equal stale, R::MarketData.execution_quote(item, stale)
        end
      end
    end
  end
  def test_legacy_twelve_data_adapter_also_respects_trade_only_policy
    with_backup do |item|
      item.update!(provider:'twelve_data')
      chart={'meta'=>{'currency'=>'USD','regularMarketPrice'=>'100',
        'regularMarketTime'=>Time.current.to_i,'exchangeDataDelayedBy'=>0}}
      calls=[]
      replace_method(R::ProviderHttp,:get,->(host,path,params){
        calls << path
        {'close'=>'101','timestamp'=>Time.current.to_i,'currency'=>'USD'}
      }) do
        [nil,:read,:background,:forex_fast,:idle,:forex_review].each do |purpose|
          R::FallbackBudget.with_context(purpose) do
            result=R::MarketData.fetch_primary_quote(item,chart:chart)
            assert_equal 'yahoo',result['source']
            assert_equal '100.0',result['price']
          end
        end
        assert_empty calls
        assert_equal 0,R::FallbackBudget.report[:total_reserved]
        result=R::MarketData.fetch_primary_quote(item,chart:chart)
        assert_equal 'twelve_data',result['source']
        assert_equal ['/quote'],calls
        assert_equal 1,R::FallbackBudget.report[:total_reserved]
      end
    end
  end

end
