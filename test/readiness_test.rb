# frozen_string_literal: true
require "/rsc/test/migration_features_test"
class ReadinessTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def archive(table, row)
    R::LegacyRecord.create!(source_table: table, source_id: SecureRandom.uuid, data: row, created_at: Time.current)
  end

  def test_read_only_stops_http_ledger_commands_jobs_and_notifications_but_allows_reads
    fund
    game = match
    prediction = R::Sports.predict(actor: @alice, match_id: game.id, pick: "home", stake: "10", request_id: "readonly-predict")
    game.update!(status: "finished", result: "home", confirmed_at: 1.day.ago)
    before = [R::Journal.count, R::Account.wallet(@alice.id).balance, Notification.count]
    SiteSetting.rsc_read_only = true
    error = assert_raises(R::Error) { R::Wallet.transfer(actor: @alice, recipient: @bob, amount: "1", request_id: "readonly-transfer") }
    assert_equal "read_only", error.code
    assert_raises(R::Error) { R::Sports.settle(game.id) }
    assert_raises(R::Error) { R::NotificationDelivery.deliver(R::Event.first) }
    assert_raises(R::Error) { R::Administration.perform(actor: @admin, action: "wallet_status", input: { "user_id" => @alice.id, "status" => "frozen", "reason" => "test" }, request_id: "readonly-freeze") }
    Jobs::DiscourseRscBusinessTick.new.execute({})
    Jobs::DiscourseRscDeliverNotifications.new.execute({})
    assert_equal "pending", R::Prediction.find(prediction["prediction_id"]).status
    assert_equal before, [R::Journal.count, R::Account.wallet(@alice.id).balance, Notification.count]
    key = ApiKey.create!(user_id: @alice.id, created_by_id: @admin.id, description: "isolated read only")
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "rsc.test"
    session.https!
    headers = { "Api-Key" => key.key, "Api-Username" => @alice.username }
    session.get "/rsc/state.json", headers: headers
    assert_equal 200, session.response.status, session.response.body
    assert JSON.parse(session.response.body)["read_only"]
    session.post "/rsc/market-requests.json", params: { symbol: "TEST" }, headers: headers, as: :json
    assert_equal 503, session.response.status
    assert_equal 0, R::MarketRequest.count
  end

  def test_merge_and_delete_are_rejected_before_core_changes_even_when_plugin_disabled
    fund
    old_name = @alice.username
    SiteSetting.rsc_enabled = false
    assert_raises(Discourse::InvalidParameters) { UserMerger.new(@alice, @bob, @admin).merge! }
    assert_equal old_name, @alice.reload.username
    assert_raises(Discourse::InvalidParameters) { UserDestroyer.new(@admin).destroy(@alice, delete_posts: true) }
    assert_raises(Discourse::InvalidParameters) { @alice.destroy! }
    assert User.exists?(@alice.id)
    assert_equal "1000", R::Account.wallet(@alice.id).balance
    error = assert_raises(ActiveRecord::StatementInvalid) { User.where(id: @alice.id).delete_all }
    # PostgreSQL 18 uses restrict_violation for ON DELETE RESTRICT; older
    # versions report foreign_key_violation. Both must retain the original user.
    assert_includes %w[23503 23001], error.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
    assert User.exists?(@alice.id)
    assert_raises(ActiveRecord::InvalidForeignKey) { R::Account.wallet(999999999) }
  end

  def test_pagination_and_public_trader_fields
    assert_equal [21, 22, 23], R::Reports.page((1..23).to_a, page: 2)[:rows]
    assert_equal 2, R::Reports.page((1..23).to_a, page: 999)[:pagination][:page]
    assert_raises(R::Error) { R::Reports.page([], page: "1x") }
    fund
    stock = instrument
    result = R::Exchange.submit(actor: @alice, instrument_id: stock.id, side: "long", quantity: "1", leverage: 5, request_id: "public-order")
    fill(stock, R::Order.find(result["order_id"]))
    report = R::Reports.trader(@alice.id, section: "orders")
    assert_equal 1, report[:rows].size
    refute report[:rows][0].key?(:details)
    refute report[:summary].key?(:balance)
    R::Account.wallet(@alice.id).update!(status: "frozen")
    assert_raises(R::Error) { R::Reports.trader(@alice.id) }
    before = R::Account.count
    R::Reports.portfolio(@bob.id)
    assert_equal before, R::Account.count, "Reading reports must not create wallets"
  end

  def test_leaderboard_keeps_more_than_twenty_and_batch_totals_match
    21.times do |i|
      user = make_user("rsc_rank_#{i}")
      @group.add(user)
      R::Account.wallet(user.id)
    end
    fund
    R::Wallet.transfer(actor: @alice, recipient: @bob, amount: "2", request_id: "ranking-transfer")
    Discourse.cache.delete("rsc:leaderboard:v3:equity:#{SiteSetting.rsc_allowed_groups}")
    rows = R::Reports.leaderboard("equity")
    assert_equal 23, rows.size
    assert_equal "998", rows.find { |row| row[:user_id] == @alice.id }[:equity]
    assert_equal "2", rows.find { |row| row[:user_id] == @bob.id }[:equity]
    assert_equal 3, R::Reports.page(rows, page: 2)[:rows].size
  end

  def test_performance_uses_flow_boundaries_and_does_not_invent_daily_returns
    archive("account_performance_periods", { discourse_user_id: @alice.id, period_key: "all-time", opening_equity_rsc: "100", starts_at: "2026-01-01T00:00:00Z", twr_factor_scaled: "1320000000000000000", segment_opening_equity_rsc: "140" })
    archive("account_performance_flows", { id: 1, discourse_user_id: @alice.id, period_key: "all-time", signed_amount_rsc: "50", equity_before_rsc: "110", created_at: "2026-01-02T00:00:00Z" })
    archive("account_performance_flows", { id: 2, discourse_user_id: @alice.id, period_key: "all-time", signed_amount_rsc: "-52", equity_before_rsc: "192", created_at: "2026-01-03T00:00:00Z" })
    result = R::Reports.performance(@alice.id)
    assert_equal ["0", "10.0", "32.0"], result[:points].map { |p| p[:return_pct] }
    assert result[:complete]
    assert_equal 3, result[:points].size
  end

  def campaign_fixture
    32.times do |i|
      game = R::SportMatch.create!(external_id: "wc-#{i}", league: "fifa.world", home: "A", away: "B", starts_at: Time.utc(2026, 7, 1), status: "finished", result: "home", provider_data: { stage: R::Campaign::STAGES[i % 6] })
      R::Prediction.create!(user_id: @alice.id, sport_match_id: game.id, pick: "home", status: "won", odds: "2", stake_units: 1, payout_units: 2)
    end
  end

  def test_campaign_keeps_legacy_paid_markers_and_never_reissues_imported_awards
    campaign_fixture
    archive("world_cup_campaign_rewards", { campaign_key: R::Campaign::KEY, discourse_user_id: @alice.id, participation_count: 32, correct_count: 32, rebate_rsc: "32", rsc_issuance_id: 7, silver_badge_grant_id: 8, gold_badge_grant_id: 9 })
    assert R::Campaign.preview[:ready]
    assert_equal 0, R::Campaign.apply(actor: @admin)[:pending]
    assert_equal 0, R::Journal.count
    assert_equal 0, R::Event.count
  end

  def test_campaign_rolls_back_missing_badges_then_pays_and_grants_once
    campaign_fixture
    SiteSetting.rsc_campaign_silver_badge_id = 0
    SiteSetting.rsc_campaign_gold_badge_id = 0
    assert_raises(R::Error) { R::Campaign.apply(actor: @admin) }
    assert_equal 0, R::Journal.count
    R::Campaign::BADGES.each do |tier, name|
      badge = Badge.find_by(name: name) || Badge.create!(name: name, badge_type_id: 2, multiple_grant: false, enabled: true)
      UserBadge.where(user_id: @alice.id, badge_id: badge.id).delete_all
      SiteSetting.public_send("rsc_campaign_#{tier}_badge_id=", badge.id)
    end
    assert_equal 0, R::Campaign.apply(actor: @admin)[:pending]
    assert_equal "32", R::Account.wallet(@alice.id).balance
    assert_equal 1, R::Journal.count
    R::Campaign.apply(actor: @admin)
    assert_equal 1, R::Journal.count
    assert_equal 2, UserBadge.joins(:badge).where(user_id: @alice.id, badges: { name: R::Campaign::BADGES.values }).count
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_archived_market_charts_are_readable_but_quotes_cannot_execute
    item = instrument
    item.update!(quote: {})
    archive("market_instruments", { id: 100, symbol: item.symbol })
    archive("market_quotes", { instrument_id: 100, price_rsc: "101.123456789012345678", source_time: Time.current.iso8601, received_at: Time.current.iso8601 })
    archive("market_candles", { instrument_id: 100, range_key: "1d", candle_time: "2026-01-01T01:00:00Z", open_rsc: "100", high_rsc: "102", low_rsc: "99", close_rsc: "101.123456789012345678", updated_at: "2026-01-01T01:01:00Z" })
    SiteSetting.rsc_read_only = true
    assert_equal({ quotes: 1, history_series: 1 }, R::LegacyMarket.restore!)
    assert_equal({ quotes: 0, history_series: 0 }, R::LegacyMarket.restore!)
    assert_equal "quote_stale", assert_raises(R::Error) { R::Exchange.price!(item.reload) }.code
    chart = R::MarketData.history(item, "1d")
    assert chart[:archived]
    assert_equal "RSC", chart[:currency]
    assert_equal "101.123456789012345678", chart[:candles].first["close"]
  end

  def test_parallel_sync_covers_76_exposed_instruments_and_rotates_idle_catalog
    SiteSetting.rsc_market_data_enabled = true
    SiteSetting.rsc_market_sync_batch = 100
    101.times do |i|
      item = R::Instrument.create!(symbol: "CAP-#{i}", name: "Capacity", provider: "yahoo", category: "us")
      R::Position.create!(user_id: @alice.id, instrument_id: item.id, side: "long", leverage: 1, quantity_units: 1, average_units: 1, margin_units: 1) if i < 76
    end
    original = R::MarketData.method(:fetch_quote)
    response = quote("100")
    R::MarketData.define_singleton_method(:fetch_quote) { |item| response }
    assert_equal 81, R::MarketData.sync.size
    assert_equal 76, R::MarketData.health[:fresh]
    refute R::MarketData.health[:capacity_ok] # 76 simultaneous Yahoo requests exceed a 45-second cycle at 1/sec.
    assert_equal 5, R::MarketData.sync.size
    assert_equal 15, R::Instrument.where(synced_at: nil).count
    3.times { assert_equal 5, R::MarketData.sync.size }
    assert_equal 0, R::Instrument.where(synced_at: nil).count
  ensure
    R::MarketData.define_singleton_method(:fetch_quote, original) if original
  end
end

class ReadinessTest
  def test_legacy_fills_are_authoritative_and_do_not_double_count_orders
    fund
    asset = instrument
    R::Order.create!(leverage: 1, user_id: @alice.id, instrument_id: asset.id, side: "close", status: "filled", quantity_units: R::Amount.parse("1"), details: { legacy_id: 1, pnl: "-500", fee: "1" })
    archive("exchange_trades", { discourse_user_id: @alice.id, side: "long", fee_rsc: "0.2", margin_rsc: "20", net_rsc: "0" })
    archive("exchange_trades", { discourse_user_id: @alice.id, side: "sell", fee_rsc: "1", margin_rsc: "20", net_rsc: "0" })
    row = R::Reports.portfolio(@alice.id)
    assert_equal "-20.2", row[:realized_pnl]
    assert_equal 2, row[:trade_count]
    assert_equal "-1.98", row[:return_pct]
  end

  def test_archived_marks_keep_holders_ranked_but_cannot_execute
    fund
    asset = instrument
    position = R::Position.create!(user_id: @alice.id, instrument_id: asset.id, side: "long", quantity_units: R::Amount.parse("1"), average_units: R::Amount.parse("100"), margin_units: R::Amount.parse("20"), leverage: 5)
    asset.update!(quote: quote("150").merge("legacy_snapshot" => true))
    row = R::Reports.portfolio(@alice.id)
    assert_equal "1070", row[:equity]
    assert_equal "last_quote", row[:valuation_basis]
    assert_raises(R::Error) { R::Exchange.price!(asset) }
    asset.update!(quote: {})
    assert_equal "cost", R::Reports.portfolio(@alice.id)[:valuation_basis]
    assert_equal "1020", R::Reports.portfolio(@alice.id)[:equity]
    asset.update!(quote: quote("1").merge("legacy_snapshot" => true))
    assert_equal "-20", R::Reports.portfolio(@alice.id)[:pnl]
  end

  def test_market_popularity_counts_all_statuses_and_breaks_ties_by_recency
    first = instrument
    second = R::Instrument.create!(symbol: "AAA", name: "Alphabetical first", category: "us", quote: quote("100"))
    [first, second].each do |asset|
      R::Order.create!(leverage: 1, user_id: @alice.id, instrument_id: asset.id, side: "long", status: "canceled", quantity_units: R::Amount.parse("1"), created_at: asset == first ? 1.hour.ago : 2.hours.ago)
    end
    assert_equal [first.id, second.id], R::MarketListing.rows([second, first]).map { |row| row[:id] }
    R::Order.create!(leverage: 1, user_id: @alice.id, instrument_id: second.id, side: "long", status: "rejected", quantity_units: R::Amount.parse("1"))
    assert_equal [second.id, first.id], R::MarketListing.rows([first, second]).map { |row| row[:id] }
  end
end

class ReadinessTest
  def test_historical_quote_without_timestamps_is_visible_but_never_executable
    SiteSetting.rsc_read_only = true
    asset = instrument
    asset.update!(quote: {})
    archive("market_instruments", { id: 99, symbol: asset.symbol })
    archive("market_quotes", { instrument_id: 99, price_rsc: "1.046775" })
    assert_equal 1, R::LegacyMarket.restore![:quotes]
    assert_equal "1.046775", asset.reload.quote["price"]
    assert_equal "last_quote", R::Valuation.mark(asset)[:basis]
    assert_raises(R::Error) { R::Exchange.price!(asset) }
  end
end
