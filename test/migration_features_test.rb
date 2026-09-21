# frozen_string_literal: true
require "/rsc/test/business_test"
class MigrationFeaturesTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def with_provider(response)
    original = R::ProviderHttp.method(:get)
    R::ProviderHttp.define_singleton_method(:get) { |*args| response.respond_to?(:call) ? response.call(*args) : response }
    yield
  ensure
    R::ProviderHttp.define_singleton_method(:get, original)
  end

  def test_crypto_high_risk_consent_cooldown_and_portfolio_caps
    fund(@alice, "1000")
    coin = instrument
    coin.update!(category: "crypto")
    assert_raises(R::Error) { R::Exchange.submit(actor: @alice, instrument_id: coin.id, side: "long", quantity: "1", leverage: 100, high_risk: true, request_id: "risk-disabled") }
    SiteSetting.rsc_high_risk_enabled = true
    result = R::Exchange.submit(actor: @alice, instrument_id: coin.id, side: "long", quantity: "1", leverage: 100, high_risk: true, request_id: "risk-consented")
    fill(coin, R::Order.find(result["order_id"]))
    closing = R::Exchange.submit(actor: @alice, instrument_id: coin.id, side: "close", quantity: "1", leverage: 1, request_id: "risk-close-all")
    fill(coin, R::Order.find(closing["order_id"]))
    error = assert_raises(R::Error) { R::Exchange.submit(actor: @alice, instrument_id: coin.id, side: "long", quantity: "1", leverage: 100, high_risk: true, request_id: "risk-cooldown") }
    assert_equal "high_risk_cooldown", error.code
    error = assert_raises(R::Error) { R::Exchange.submit(actor: @alice, instrument_id: coin.id, side: "long", quantity: "90", leverage: 10, request_id: "risk-over-budget") }
    assert_equal "position_risk_limit", error.code
  end

  def test_margin_addition_changes_liquidation_and_preserves_ledger
    fund
    stock = instrument
    result = R::Exchange.submit(actor: @alice, instrument_id: stock.id, side: "long", quantity: "1", leverage: 5, request_id: "margin-order")
    fill(stock, R::Order.find(result["order_id"]))
    position = R::Position.first
    assert_equal "85", R::Risk.liquidation(position)
    R::Exchange.add_margin(actor: @alice, position_id: position.id, amount: "20", request_id: "margin-addition")
    assert_equal "70", R::Risk.liquidation(position.reload)
    assert_equal "40", R::Account.internal("position:#{position.id}").balance
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_admin_freeze_cancels_orders_and_adjustment_is_audited_idempotent
    fund
    stock = instrument
    stock.update!(quote: stock.quote.merge("delay_seconds" => 120))
    R::Exchange.submit(actor: @alice, instrument_id: stock.id, side: "long", quantity: "1", leverage: 1, request_id: "admin-pending")
    args = { actor: @admin, action: "wallet_status", input: { "user_id" => @alice.id.to_s, "status" => "frozen", "reason" => "test freeze" }, request_id: "admin-freeze" }
    R::Administration.perform(**args)
    assert_equal "1000", R::Account.wallet(@alice.id).balance
    assert_equal "canceled", R::Order.first.status
    assert R::Administration.perform(**args)["replayed"]
    assert_equal 1, R::Audit.count
    assert_raises(R::Error) { R::Administration.perform(**args.merge(actor: @alice)) }
    R::Administration.perform(actor: @admin, action: "reset_assets", input: { "user_id" => @alice.id.to_s, "amount" => "12.50", "reason" => "test reset" }, request_id: "admin-adjust")
    assert_equal "12.5", R::Account.wallet(@alice.id).balance
    assert_equal "frozen", R::Account.wallet(@alice.id).status
    assert_equal 0, R::Entry.sum(:units)
  end

  def espn_event(name: "STATUS_FINAL_AET", lines: false)
    teams = [{ "homeAway" => "home", "team" => { "displayName" => "Home", "id" => "1" }, "score" => "2" }, { "homeAway" => "away", "team" => { "displayName" => "Away", "id" => "2" }, "score" => "1" }]
    teams.each { |team| team["linescores"] = [{ "period" => 1, "value" => 0 }, { "period" => 2, "value" => 1 }, { "period" => 3, "value" => 1 }] } if lines
    { "id" => "fixture-1", "date" => 1.day.ago.iso8601, "competitions" => [{ "status" => { "type" => { "name" => name, "state" => "post", "completed" => true } }, "competitors" => teams }] }
  end

  def test_football_extra_time_requires_regulation_evidence_and_confirmation
    R::SportsData.ingest(espn_event, sport: "soccer", league: "eng.1")
    game = R::SportMatch.first
    assert_nil game.result
    assert game.provider_data["result_pending_review"]
    R::SportsData.ingest(espn_event(lines: true), sport: "soccer", league: "eng.1")
    assert_equal "draw", game.reload.result
    first_confirmation = game.confirmed_at
    R::SportsData.ingest(espn_event(lines: true), sport: "soccer", league: "eng.1")
    assert_equal first_confirmation, game.reload.confirmed_at
    assert_equal "2.5", R::SportsData.american("+150")
    assert_equal "1.5", R::SportsData.american("-200")
  end

  def test_provider_failure_keeps_quote_time_and_disables_trading_when_stale
    stock = instrument
    stock.update!(provider: "yahoo", quote: quote("100").merge("received_at" => 10.minutes.ago.iso8601, "source_time" => 10.minutes.ago.iso8601))
    with_provider(->(*) { raise R::Error.new("provider_http_429") }) do
      refute R::MarketData.sync_one(stock)
    end
    assert_equal "provider_http_429", stock.reload.provider_error
    assert_raises(R::Error) { R::Exchange.price!(stock) }
    meta = { "chart" => { "result" => [{ "meta" => { "currency" => "USD", "regularMarketPrice" => "102.25", "chartPreviousClose" => "100", "regularMarketTime" => Time.current.to_i, "exchangeDataDelayedBy" => 15, "currentTradingPeriod" => { "regular" => { "start" => 1.hour.ago.to_i, "end" => 1.hour.from_now.to_i } } } }] } }
    with_provider(meta) { assert R::MarketData.sync_one(stock) }
    assert_equal "102.25", stock.reload.quote["price"]
    assert_equal 900, stock.quote["delay_seconds"]
    assert_nil stock.provider_error
  end

  def test_import_rehearsal_and_commit_reconcile_without_replaying_balances
    payload = { format: "rsc-native-export-v1", tables: {
      users: [{ discourse_user_id: @alice.id }], point_accounts: [{ discourse_user_id: @alice.id, balance_rsc: "12.34567890123456789", status: "active" }],
      market_instruments: [{ id: 5, symbol: "TEST", name: "Test", min_quantity: "1", quantity_step: "1", is_active: 1 }],
      positions: [{ id: 7, discourse_user_id: @alice.id, instrument_id: 5, quantity: "2", average_price_rsc: "100", margin_rsc: "20", leverage: 10 }],
      exchange_orders: [{ id: 8, discourse_user_id: @alice.id, instrument_id: 5, quantity: "1", side: "long", status: "pending", reserved_rsc: "10", created_at: Time.current.iso8601 },
                        { id: 9, discourse_user_id: @alice.id, instrument_id: 5, quantity: "1", side: "long", status: "cancelled", created_at: Time.current.iso8601 }],
      reward_payouts: [{ discourse_user_id: @alice.id, date: Date.yesterday.iso8601, amount_rsc: "1", status: "success" }] } }
    file = Tempfile.new("rsc-import")
    file.write(JSON.generate(payload)); file.close
    report = R::LegacyImport.run(file.path)
    assert report[:balanced]
    assert_equal "32.34567890123456789", report[:opening_assets]
    assert_equal 0, R::Journal.count
    assert_equal 0, R::LegacyRecord.count
    SiteSetting.rsc_enabled = false
    R::LegacyImport.run(file.path, apply: true, expected_sha256: report[:sha256])
    assert_equal "12.34567890123456789", R::Account.wallet(@alice.id).balance
    assert_equal "20", R::Account.internal("position:#{R::Position.first.id}").balance
    assert_equal "canceled", R::Order.first.status
    assert_equal ["canceled"], R::Order.distinct.pluck(:status)
    assert R::Command.exists?(key: "daily_reward:#{@alice.id}:daily-#{Date.yesterday.iso8601}")
    assert_raises(R::Error) { R::LegacyImport.run(file.path) }
  ensure
    file&.unlink
  end

  def test_import_missing_identity_fails_before_archiving_history
    payload = { format: "rsc-native-export-v1", tables: { users: [{ discourse_user_id: User.maximum(:id) + 1000 }], ledger_entries: [{ id: 1 }] } }
    file = Tempfile.new("rsc-missing-identity")
    file.write(JSON.generate(payload)); file.close
    original = R::LegacyRecord.method(:insert_all!)
    test = self
    R::LegacyRecord.define_singleton_method(:insert_all!) { |*| test.flunk "history must not be written before identity validation" }
    error = assert_raises(R::Error) { R::LegacyImport.run(file.path) }
    assert_match(/import_missing_user_/, error.code)
    assert_equal 0, R::Journal.count
    assert_equal 0, R::LegacyRecord.count
  ensure
    R::LegacyRecord.define_singleton_method(:insert_all!, original) if original
    file&.unlink
  end

  def test_import_batches_preserve_idless_history_and_reward_idempotency
    dates = (0..500).map { |i| (Date.new(2020, 1, 1) + i).iso8601 }
    history = dates.map { |date| { date: date, marker: "history-without-id" } }
    payload = { format: "rsc-native-export-v1", tables: {
      users: [{ discourse_user_id: @alice.id }],
      daily_activity: history,
      world_cup_campaign_rewards: [{ id: 7, discourse_user_id: @alice.id, rebate_rsc: "12" }],
      reward_payouts: dates.map { |date| { discourse_user_id: @alice.id, date: date, status: "success" } }
    } }
    file = Tempfile.new("rsc-batched-history")
    file.write(JSON.generate(payload)); file.close
    SiteSetting.rsc_enabled = false
    R::LegacyImport.run(file.path, apply: true, expected_sha256: Digest::SHA256.file(file.path).hexdigest)
    assert_equal history.first, R::LegacyRecord.find_by!(source_table: "daily_activity", source_id: "0").data.symbolize_keys
    assert_equal history.last, R::LegacyRecord.find_by!(source_table: "daily_activity", source_id: "500").data.symbolize_keys
    assert_equal 501, R::LegacyRecord.where(source_table: "daily_activity").count
    assert_equal 501, R::Command.where("key LIKE 'daily_reward:%'").count
    assert R::Command.exists?(key: "daily_reward:#{@alice.id}:daily-#{dates.last}")
    assert_equal "12", R::LegacyRecord.find_by!(source_table: "world_cup_campaign_rewards").data["rebate_rsc"]
    assert_equal 0, R::Journal.count, "Historical rewards must not issue funds again"
  ensure
    file&.unlink
  end

  def test_rehearsal_subset_is_refused_outside_disposable_environment
    original = ENV["RSC_DISPOSABLE_CONTAINER"]
    file = Tempfile.new("rsc-subset-guard")
    file.write(JSON.generate({ format: "rsc-native-export-v1", rehearsal_subset: {}, tables: {} })); file.close
    ENV["RSC_DISPOSABLE_CONTAINER"] = "0"
    error = assert_raises(R::Error) { R::LegacyImport.run(file.path) }
    assert_equal "import_subset_requires_disposable_database", error.code
    assert_equal 0, R::LegacyRecord.count
  ensure
    ENV["RSC_DISPOSABLE_CONTAINER"] = original
    file&.unlink
  end

  def test_batched_openings_preserve_precision_and_rollback_all_batches
    amount = "1.000000000000000001"
    payload = { format: "rsc-native-export-v1", tables: {
      users: [{ discourse_user_id: @alice.id }],
      point_accounts: [{ discourse_user_id: @alice.id, balance_rsc: amount, status: "active" }],
      market_instruments: (1..101).map { |i| { id: i, symbol: "BATCH-#{i}", name: "Batch #{i}" } },
      positions: (1..101).map { |i| { id: i, discourse_user_id: @alice.id, instrument_id: i, quantity: "1", average_price_rsc: "1", margin_rsc: amount } }
    } }
    file = Tempfile.new("rsc-opening-batches")
    payload[:tables][:positions].last[:quantity] = "invalid"
    file.write(JSON.generate(payload)); file.close
    assert_raises(R::Error) { R::LegacyImport.run(file.path) }
    assert_equal 0, R::Journal.count
    assert_equal 0, R::Account.count
    assert_equal 0, R::LegacyRecord.count
    payload[:tables][:positions].last[:quantity] = "1"
    File.write(file.path, JSON.generate(payload))
    SiteSetting.rsc_enabled = false
    report = R::LegacyImport.run(file.path, apply: true, expected_sha256: Digest::SHA256.file(file.path).hexdigest)
    assert_equal R::Amount.format(R::Amount.parse(amount) * 102), report[:opening_assets]
    assert_equal amount, R::Account.wallet(@alice.id).balance
    assert_equal 101, R::Account.where(kind: "escrow").count
    assert R::Account.where(kind: "escrow").all? { |a| a.balance == amount }
    assert_equal 2, R::Journal.count
    assert_equal 0, R::Entry.sum(:units)
  ensure
    file&.unlink
  end
  def test_admin_http_permissions_and_member_history_are_isolated
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "rsc.test"
    session.https!
    member_key = ApiKey.create!(user_id: @alice.id, created_by_id: @admin.id, description: "isolated feature permission")
    admin_key = ApiKey.create!(user_id: @admin.id, created_by_id: @admin.id, description: "isolated admin permission")
    headers = { "Api-Key" => member_key.key, "Api-Username" => @alice.username }
    session.get "/rsc/admin/state.json", headers: headers
    assert_equal 403, session.response.status
    R::LegacyRecord.create!(source_table: "ledger_entries", source_id: "alice", data: { discourse_user_id: @alice.id, amount_rsc: "1" }, created_at: Time.current)
    R::LegacyRecord.create!(source_table: "ledger_entries", source_id: "bob", data: { discourse_user_id: @bob.id, amount_rsc: "999" }, created_at: Time.current)
    session.get "/rsc/legacy-entries.json", headers: headers, params: { user_id: @bob.id, before: "" }
    assert_equal 200, session.response.status
    assert_equal ["1"], JSON.parse(session.response.body).fetch("entries").map { |row| row["amount_rsc"] }
    session.get "/rsc/admin/state.json", headers: { "Api-Key" => admin_key.key, "Api-Username" => @admin.username }
    assert_equal 200, session.response.status, session.response.body
    fund
    coin = instrument
    coin.update!(category: "crypto")
    SiteSetting.rsc_high_risk_enabled = true
    session.post "/rsc/orders.json", headers: headers, as: :json, params: { instrument_id: coin.id, side: "long", quantity: "1", leverage: 100, high_risk: true, request_id: "json-high-risk" }
    assert_equal 200, session.response.status, session.response.body
    assert_equal 100, R::Order.last.leverage
    R::Administration.perform(actor: @admin, action: "instrument", input: { "symbol" => "INACTIVE", "active" => false, "reason" => "JSON boolean check" }, request_id: "json-inactive")
    refute R::Instrument.find_by!(symbol: "INACTIVE").active
  end

  def test_catalog_and_real_public_response_shapes
    assert_equal ["yahoo", "0700.HK"], R::Catalog.provider({ "symbol" => "HKEX:700", "display_symbol" => "700", "exchange" => "HKEX" })
    assert_equal ["kraken", "XMRUSD"], R::Catalog.provider({ "symbol" => "CRYPTO:XMR/USD", "market_category" => "crypto" })
    assert_equal ["okx", "SNDK-USDT-SWAP"], R::Catalog.provider({ "symbol" => "CRYPTO:SNDK/USD", "market_category" => "crypto" })
    stock = instrument
    stock.update!(provider: "coinbase", provider_symbol: "BTC-USD", category: "crypto")
    ticker = JSON.parse(File.read("/rsc/test/fixtures/coinbase-ticker.json"))
    stats = JSON.parse(File.read("/rsc/test/fixtures/coinbase-stats.json"))
    with_provider(->(host, path, *args) { path.end_with?("stats") ? stats : ticker }) do
      quote = R::MarketData.fetch_quote(stock)
      assert_equal BigDecimal(ticker.fetch("price")), BigDecimal(quote.fetch("price"))
      assert_in_delta Time.iso8601(ticker.fetch("time")).to_f, Time.iso8601(quote.fetch("source_time")).to_f, 0.000001
      assert_equal "coinbase", quote["source"]
    end
    espn = JSON.parse(File.read("/rsc/test/fixtures/espn-scoreboard.json"))
    espn.fetch("events").each { |event| R::SportsData.ingest(event, sport: "soccer", league: "eng.1") }
    assert_equal espn.fetch("events").size, R::SportMatch.count
  end

  def test_import_prediction_and_partially_claimed_packet_escrows
    now = Time.current.iso8601
    payload = { format: "rsc-native-export-v1", tables: {
      point_accounts: [{ discourse_user_id: @alice.id, balance_rsc: "100", status: "active" }, { discourse_user_id: @bob.id, balance_rsc: "20", status: "active" }],
      world_cup_matches: [{ id: 1, external_id: "import-game", home_team: "Home", away_team: "Away", starts_at: 1.day.from_now.iso8601, status: "scheduled", odds_home: "2" }],
      world_cup_predictions: [{ id: 1, discourse_user_id: @alice.id, match_id: 1, pick: "home", stake_rsc: "10", odds_decimal: "2", status: "pending", created_at: now }],
      rsc_red_packets: [{ id: 1, creator_discourse_user_id: @alice.id, public_token: "legacy-public-token", amount_mode: "random", total_rsc: "5", remaining_rsc: "3", status: "open", max_claims: 2, expires_at: 1.day.from_now.iso8601, created_at: now }],
      rsc_red_packet_claims: [{ id: 1, packet_id: 1, recipient_discourse_user_id: @bob.id, amount_rsc: "2", created_at: now }],
      rsc_red_packet_allocations: [{ packet_id: 1, sequence: 1, amount_rsc: "2", claim_id: 1 }, { packet_id: 1, sequence: 2, amount_rsc: "3", claim_id: nil }] } }
    file = Tempfile.new("rsc-escrow-import")
    file.write(JSON.generate(payload)); file.close
    report = R::LegacyImport.run(file.path)
    assert_equal "133", report[:opening_assets]
    assert_equal "10", report[:totals][:predictions]
    assert_equal "3", report[:totals][:packets]
    SiteSetting.rsc_enabled = false
    R::LegacyImport.run(file.path, apply: true, expected_sha256: report[:sha256])
    game = R::SportMatch.first
    game.update!(status: "canceled")
    R::Sports.settle(game.id)
    R::RedPackets.close(actor: @alice, token: "legacy-public-token", request_id: "import-close-packet")
    assert_equal "113", R::Account.wallet(@alice.id).balance
    assert_equal "20", R::Account.wallet(@bob.id).balance
    assert_equal 0, R::Account.where(kind: "escrow").sum(:balance_units)
    assert_equal 0, R::Entry.sum(:units)
  ensure
    file&.unlink
  end

  def test_closed_stock_market_does_not_block_crypto_using_available_cash
    fund
    stock = instrument
    result = R::Exchange.submit(actor: @alice, instrument_id: stock.id, side: "long", quantity: "1", leverage: 5, request_id: "weekend-stock")
    fill(stock, R::Order.find(result["order_id"]))
    stock.update!(quote: quote("100").merge("source_time" => 2.days.ago.iso8601, "received_at" => 2.days.ago.iso8601))
    coin = R::Instrument.create!(symbol: "WEEKEND-COIN", name: "Weekend coin", category: "crypto", quote: quote("100"))
    result = R::Exchange.submit(actor: @alice, instrument_id: coin.id, side: "long", quantity: "1", leverage: 5, request_id: "weekend-crypto")
    assert_equal "pending", result["status"]
    assert_equal 2, R::Order.count
    assert_equal 0, R::Entry.sum(:units)
  end

end
