# frozen_string_literal: true
require '/rsc/test/forex_primary_policy_test'
class ForexMorningTest < ForexPrimaryPolicyTest
  ForexPrimaryPolicyTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def setup
    super
    SiteSetting.rsc_market_data_enabled = true
    Discourse.redis.keys('rsc:fx-morning:*').each { |key| Discourse.redis.del(key) }
  end

  def morning_fx(code)
    item = forex("FX:#{code}")
    item.update!(provider: 'yahoo', provider_symbol: "#{code}=X", synced_at: 1.hour.ago,
      quote: observation('1', at: 1.hour.ago).merge('received_at'=>1.hour.ago.iso8601))
    item
  end

  def with_refresh(fail_id: nil)
    original = R::MarketData.method(:refresh_if_needed)
    calls = []
    R::MarketData.define_singleton_method(:refresh_if_needed) do |id, purpose:|
      calls << [id, purpose]
      raise R::Error.new("provider_cooldown") if id == fail_id
      R::Instrument.find(id)
    end
    yield calls
  ensure
    R::MarketData.define_singleton_method(:refresh_if_needed, original)
  end

  def next_batch
    # Redis uses real clocks; expire the pacing marker without sleeping in tests.
    Discourse.redis.del("#{R::MarketData.forex_morning_key}:batch")
    travel 1.minute
  end

  def test_morning_window_is_beijing_weekday_and_independent_of_dst
    [Time.utc(2026,7,6), Time.utc(2026,11,2)].each do |morning|
      travel_to(morning - 1.second) { refute R::MarketData.forex_morning_due? }
      travel_to(morning) { assert R::MarketData.forex_morning_due? }
      travel_to(morning + 3599) { assert R::MarketData.forex_morning_due? }
      travel_to(morning + 3600) { refute R::MarketData.forex_morning_due? }
    end
    travel_to(Time.utc(2026,11,1)) { refute R::MarketData.forex_morning_due? }
    travel_to(Time.utc(2026,11,7)) { refute R::MarketData.forex_morning_due? }
  end

  def test_morning_batches_prioritize_exposure_and_resume_once_per_day
    travel_to(Time.utc(2026,11,2)) do
      items = %w[EUR JPY CNY BRL GBP].map { |code| morning_fx(code) }
      R::Position.create!(user_id:@alice.id,instrument_id:items[3].id,side:'long',leverage:1,
        quantity_units:1,average_units:1,margin_units:1)
      R::Order.create!(user_id:@alice.id,instrument_id:items[4].id,side:'long',leverage:1,
        quantity_units:1,reserved_units:0,status:'pending',execute_at:Time.current,expires_at:1.hour.from_now)
      yielded=[]
      with_refresh do |calls|
        R::MarketData.sync_forex_morning { |id| yielded << id }
        assert_equal [items[4].id,items[3].id,items[0].id],calls.map(&:first)
        assert_equal calls.map(&:first),yielded
        assert calls.all? { |_,purpose| purpose==:background }
        assert_empty R::MarketData.sync_forex_morning
        next_batch
        R::MarketData.sync_forex_morning
        assert_equal items.map(&:id).sort,calls.map(&:first).sort
        next_batch
        R::MarketData.sync_forex_morning
        refute R::MarketData.forex_morning_due?
        travel 1.day
        assert R::MarketData.forex_morning_due?
      end
    end
  end

  def test_morning_never_uses_backup_for_stale_normal_primary_and_honors_retry
    travel_to(Time.utc(2026,11,2)) do
      item=morning_fx('CNY')
      SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
      with_feeds(observation('1',at:1.hour.ago),R::Error.new('provider_daily_limit')) do |calls|
        R::MarketData.sync_forex_morning
        assert_equal 1,calls[:primary]
        assert_equal 0,calls[:backup]
        refute R::ForexQuoteGuard.fresh?(item.reload.quote)
      end
      next_batch
      other=morning_fx('EUR')
      other.update!(provider_error:'provider_http_429',synced_at:Time.current)
      with_feeds(R::Error.new('should_not_request'),R::Error.new('should_not_request')) do |calls|
        R::MarketData.sync_forex_morning
        assert_equal({primary:0,backup:0},calls)
      end
    end
  end

  def test_morning_skips_inactive_non_fx_and_direct_paid_sources
    travel_to(Time.utc(2026,11,2)) do
      morning_fx('CNY').update!(active:false)
      morning_fx('EUR').update!(category:'us')
      morning_fx('JPY').update!(provider:'twelve_data')
      with_refresh do |calls|
        assert_empty R::MarketData.sync_forex_morning
        assert_empty calls
      end
    end
  end


  def test_morning_provider_failure_does_not_block_remaining_symbols
    travel_to(Time.utc(2026,11,2)) do
      items = %w[EUR JPY CNY BRL].map { |code| morning_fx(code) }
      with_refresh(fail_id: items.first.id) do |calls|
        assert_equal [items[1].id,items[2].id], R::MarketData.sync_forex_morning
        next_batch
        assert_equal [items[3].id], R::MarketData.sync_forex_morning
        assert_equal items.map(&:id),calls.map(&:first)
      end
    end
  end

  def test_morning_stops_when_disabled_or_read_only
    travel_to(Time.utc(2026,11,2)) do
      morning_fx('CNY')
      with_refresh do |calls|
        SiteSetting.rsc_market_data_enabled=false
        assert_empty R::MarketData.sync_forex_morning
        SiteSetting.rsc_market_data_enabled=true
        SiteSetting.rsc_read_only=true
        assert_empty R::MarketData.sync_forex_morning
        assert_empty calls
      end
    end
  end
end
