# frozen_string_literal: true
class FinalReviewTest < CompletionTest
  CompletionTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def with_quote_fetcher(&block)
    original = R::MarketData.method(:fetch_quote)
    calls = []
    fresh = quote('100')
    R::MarketData.define_singleton_method(:fetch_quote) do |item|
      raise 'HTTP inside money transaction' if ActiveRecord::Base.connection.transaction_open?
      calls << item.id
      fresh.deep_dup
    end
    block.call(calls)
  ensure
    R::MarketData.define_singleton_method(:fetch_quote, original)
  end

  def stale_stock
    item = instrument
    item.update!(provider: 'yahoo', provider_symbol: 'DEMO',
      quote: quote('100').merge('received_at' => 2.hours.ago.iso8601, 'source_time' => 2.hours.ago.iso8601))
    SiteSetting.rsc_market_data_enabled = true
    item
  end

  def test_idle_instrument_refreshes_without_moving_money_and_shares_cache
    item = stale_stock
    before = [R::Account.count, R::Journal.count, R::Order.count]
    with_quote_fetcher do |calls|
      3.times { R::MarketData.refresh_if_needed(item.id) }
      assert_equal [item.id], calls
      assert_equal R::Amount.parse('100'), R::Exchange.price!(item.reload, trading: true)
    end
    assert_equal before, [R::Account.count, R::Journal.count, R::Order.count]
  end

  def test_order_refreshes_idle_quote_before_locking_and_replay_never_fetches
    fund
    item = stale_stock
    with_quote_fetcher do |calls|
      args = {actor: @alice, instrument_id: item.id, side: 'long', quantity: '1', leverage: 1, request_id: 'fresh-before-order'}
      result = R::Exchange.submit(**args)
      assert_equal 'filled', result['status']
      item.update!(quote: {}, synced_at: nil)
      assert R::Exchange.submit(**args)['replayed']
      assert_equal [item.id], calls
      assert_equal 1, R::Position.count
      assert_equal 0, R::Entry.sum(:units)
    end
  end

  def test_quote_refresh_respects_readonly_disabled_and_inactive_markets
    item = stale_stock
    with_quote_fetcher do |calls|
      SiteSetting.rsc_read_only = true
      R::MarketData.refresh_if_needed(item.id)
      SiteSetting.rsc_read_only = false
      SiteSetting.rsc_market_data_enabled = false
      R::MarketData.refresh_if_needed(item.id)
      SiteSetting.rsc_market_data_enabled = true
      item.update!(active: false)
      R::MarketData.refresh_if_needed(item.id)
      assert_empty calls
    end
  ensure
    SiteSetting.rsc_read_only = false
  end

  def test_failed_refresh_never_makes_old_price_tradable_and_throttles_retries
    item = stale_stock
    original = R::MarketData.method(:fetch_quote)
    calls = 0
    R::MarketData.define_singleton_method(:fetch_quote) { |_| calls += 1; raise R::Error.new('provider_unavailable') }
    3.times { R::MarketData.refresh_if_needed(item.id) }
    assert_equal 1, calls
    assert_equal 'provider_unavailable', item.reload.provider_error
    assert_equal 'quote_stale', assert_raises(R::Error) { R::Exchange.price!(item) }.code
    assert_equal 0, R::Journal.count
  ensure
    R::MarketData.define_singleton_method(:fetch_quote, original)
  end

  def test_quote_refresh_endpoint_needs_membership_and_writable_mode
    item = stale_stock
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host!('rsc.test'); session.https!
    key = ApiKey.create!(user_id: @alice.id, created_by_id: @admin.id, description: 'isolated quote review')
    headers = {'Api-Key' => key.key, 'Api-Username' => @alice.username}
    with_quote_fetcher do |calls|
      SiteSetting.rsc_read_only = true
      session.post "/rsc/instruments/#{item.id}/refresh.json", headers: headers
      assert_equal 503, session.response.status
      SiteSetting.rsc_read_only = false
      @group.remove(@alice)
      session.post "/rsc/instruments/#{item.id}/refresh.json", headers: headers
      assert_equal 403, session.response.status
      assert_empty calls
      @group.add(@alice)
      session.post "/rsc/instruments/#{item.id}/refresh.json", headers: headers
      assert_equal 200, session.response.status, session.response.body
      assert_equal item.id, JSON.parse(session.response.body).dig('instrument', 'id')
      assert_equal [item.id], calls
    end
  ensure
    key&.destroy!
    SiteSetting.rsc_read_only = false
  end

  def test_reward_scheduler_keeps_legacy_two_am_boundary_and_seven_day_catchup
    SiteSetting.rsc_daily_reward_delay_hours = 2
    before = R::Rewards.catchup_dates(Time.utc(2026, 9, 21, 17, 59, 59))
    after = R::Rewards.catchup_dates(Time.utc(2026, 9, 21, 18))
    assert_equal '2026-09-20', before.last
    assert_equal '2026-09-21', after.last
    assert_equal (Date.new(2026, 9, 15)..Date.new(2026, 9, 21)).map(&:iso8601), after
    assert_equal after, R::Rewards.catchup_dates(Time.utc(2026, 9, 22, 10))
  end

  def test_provider_chart_retains_actual_pence_units_including_cached_responses
    item = stale_stock
    item.update!(currency: 'GBP', provider_symbol: 'DEMO.L')
    data = JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))
    data.fetch('chart').fetch('result').first.fetch('meta')['currency'] = 'GBp'
    with_provider(data) do
      first = R::MarketData.history(item, '1d')
      assert_equal 'GBp', first[:currency]
      assert_equal 'GBp', R::MarketData.history(item, '1d')[:currency]
      assert_equal 'GBp', R::HistoryCache.find_by!(instrument_id: item.id).currency
    end
  end

  def test_sports_sync_covers_all_nineteen_original_sources_including_unsupported_before
    original = SiteSetting.rsc_sports_leagues
    sources = %w[soccer:fifa.world soccer:uefa.champions soccer:eng.1 soccer:esp.1 soccer:ger.1 soccer:ita.1 soccer:fra.1 soccer:uefa.europa soccer:chn.1 soccer:uefa.euro soccer:conmebol.america soccer:afc.asian.cup soccer:fifa.worldq.afc soccer:fifa.cwc soccer:eng.fa soccer:esp.copa_del_rey basketball:nba basketball:fiba basketball:mens-olympics-basketball]
    SiteSetting.rsc_sports_leagues = sources.join('|')
    paths = []
    with_provider(->(host, path, **query) { assert_match(/\A[0-9]{6}\z/, query.fetch(:dates)); paths << path; {'events' => []} }) do
      result = R::SportsData.sync
      assert_equal sources.sort, (result.keys - ['pending_recheck']).sort
      assert_equal 19, paths.uniq.size
      assert sources.all? { |source| result[source] }
    end
  ensure
    SiteSetting.rsc_sports_leagues = original
  end

  def test_espn_month_buckets_cover_legacy_window_at_year_and_month_boundaries
    assert_equal %w[202609], R::SportsData.date_buckets(Time.utc(2026, 9, 21))
    assert_equal %w[202608 202609], R::SportsData.date_buckets(Time.utc(2026, 9, 2))
    assert_equal %w[202612 202701], R::SportsData.date_buckets(Time.utc(2026, 12, 29))
  end

  def test_sports_confirmation_waits_full_legacy_ten_minutes
    fund
    game = match
    R::Sports.predict(actor: @alice, match_id: game.id, pick: 'home', stake: '10', request_id: 'full-ten-minutes')
    SiteSetting.rsc_sports_settlement_delay_seconds = 600
    game.update!(status: 'finished', result: 'home', confirmed_at: 6.minutes.ago)
    assert_equal 0, R::Sports.settle(game.id)
    game.update!(confirmed_at: 11.minutes.ago)
    assert_equal 1, R::Sports.settle(game.id)
    assert_equal 0, R::Sports.settle(game.id)
  end
end
