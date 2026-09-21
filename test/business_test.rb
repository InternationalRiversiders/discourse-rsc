# frozen_string_literal: true
require "/rsc/test/discourse_smoke"

class NativeBusinessTest < DiscourseSmokeTest
  DiscourseSmokeTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }
  R = DiscourseRsc

  def fund(user = @alice, amount = "1000")
    R::Wallet.issue(actor: @admin, recipient: user, amount: amount, reason: "isolated trial", request_id: SecureRandom.uuid)
  end

  def match
    R::SportMatch.create!(external_id: SecureRandom.uuid, league: "Demo league", home: "Home", away: "Away",
                         starts_at: 1.day.from_now, odds_at: Time.current, odds: { home: "2", away: "3", draw: "3.5" })
  end

  def instrument(price = "100")
    R::Instrument.create!(symbol: "DEMO", name: "Demo stock", category: "us", quote: quote(price))
  end

  def quote(price)
    { "price" => price, "source_time" => Time.current.iso8601(6), "received_at" => Time.current.iso8601(6), "delay_seconds" => 0,
      "session_start" => 1.hour.ago.iso8601, "session_end" => 8.hours.from_now.iso8601 }
  end

  def fill(instrument, order)
    order.update!(created_at: 6.minutes.ago, execute_at: 1.second.ago)
    instrument.update!(quote: quote("100"))
    R::Exchange.process(instrument.id)
    assert_equal "filled", order.reload.status
  end

  def test_prediction_locks_odds_edits_and_settles_exactly_once
    fund(@alice, "100")
    game = match
    result = R::Sports.predict(actor: @alice, match_id: game.id, pick: "home", stake: "20", request_id: "predict-first")
    assert_equal "80", R::Account.wallet(@alice.id).balance
    game.update!(odds: { home: "9", away: "3", draw: "3" }, status: "finished", result: "home", confirmed_at: 10.minutes.ago)
    assert_equal 1, R::Sports.settle(game.id)
    assert_equal "120", R::Account.wallet(@alice.id).balance
    assert_equal "won", R::Prediction.find(result["prediction_id"]).status
    assert_equal 0, R::Sports.settle(game.id)
    event = R::Event.find_by!(kind: "prediction_settled")
    R::NotificationDelivery.deliver(event)
    assert_equal "/rsc/sports?match_id=#{game.id}#rsc-match-#{game.id}", Notification.find(event.reload.notification_id).data_hash["rsc_path"]
  end

  def test_prediction_edit_refund_and_frozen_cancellation
    fund(@alice, "100")
    game = match
    result = R::Sports.predict(actor: @alice, match_id: game.id, pick: "home", stake: "20", request_id: "predict-first")
    R::Sports.predict(actor: @alice, match_id: game.id, pick: "away", stake: "10", prediction_id: result["prediction_id"], request_id: "predict-second")
    assert_equal "90", R::Account.wallet(@alice.id).balance
    assert_equal 1, R::Prediction.find(result["prediction_id"]).revisions.size
    R::Account.wallet(@alice.id).update!(status: "frozen")
    game.update!(status: "canceled")
    R::Sports.settle(game.id)
    assert_equal "100", R::Account.wallet(@alice.id).balance
    assert_equal "refunded", R::Prediction.find(result["prediction_id"]).status
  end

  def test_prediction_start_and_stale_odds_rejected_without_spending
    fund(@alice, "100")
    game = match
    game.update!(odds_at: 7.hours.ago)
    error = assert_raises(R::Error) { R::Sports.predict(actor: @alice, match_id: game.id, pick: "home", stake: "10", request_id: "stale-predict") }
    assert_equal "odds_unavailable", error.code
    game.update!(odds_at: Time.current, starts_at: 1.second.ago)
    error = assert_raises(R::Error) { R::Sports.predict(actor: @alice, match_id: game.id, pick: "home", stake: "10", request_id: "late-predict") }
    assert_equal "match_locked", error.code
    assert_equal "100", R::Account.wallet(@alice.id).balance
  end

  def test_packet_claim_replay_and_remainder_refund
    fund(@alice, "100")
    packet = R::RedPackets.create(actor: @alice, mode: "fixed", count: 3, amount: "2", request_id: "packet-create")
    result = R::RedPackets.claim(actor: @bob, token: packet["token"], request_id: "packet-claim")
    assert_equal "2", result["amount"]
    assert R::RedPackets.claim(actor: @bob, token: packet["token"], request_id: "packet-claim")["replayed"]
    assert_equal "2", R::Account.wallet(@bob.id).balance
    assert_raises(R::Error) { R::RedPackets.claim(actor: @bob, token: packet["token"], request_id: "packet-again") }
    R::RedPackets.close(actor: @alice, token: packet["token"], request_id: "packet-close")
    assert_equal "98", R::Account.wallet(@alice.id).balance
    assert_equal 1, R::Event.where(kind: "red_packet_refund").count
  end

  def test_packet_random_allocation_conserves_amount_and_expiry_commits_refund
    fund(@alice, "100")
    result = R::RedPackets.create(actor: @alice, mode: "random", count: 20, amount: "10", minimum: "0.10", maximum: "1", request_id: "packet-random")
    packet = R::Packet.find_by!(token: result["token"])
    assert_equal R::Amount.parse("10"), packet.allocations.sum(&:to_i)
    assert packet.allocations.all? { |value| value.to_i.between?(R::Amount.parse("0.1"), R::Amount.parse("1")) }
    packet.update!(expires_at: 1.second.ago)
    assert_raises(R::Error) { R::RedPackets.claim(actor: @bob, token: packet.token, request_id: "packet-expired") }
    assert_equal "100", R::Account.wallet(@alice.id).balance
    assert_equal "expired", packet.reload.status
  end

  def test_stock_reservation_fill_and_profitable_close
    fund
    asset = instrument
    args = { actor: @alice, instrument_id: asset.id, side: "long", quantity: "1", leverage: 5, request_id: "order-first" }
    result = R::Exchange.submit(**args)
    assert R::Exchange.submit(**args)["replayed"]
    order = R::Order.find(result["order_id"])
    assert_operator R::Account.wallet(@alice.id).balance_units.to_i, :<, R::Amount.parse("1000")
    fill(asset, order)
    assert_equal "979.95", R::Account.wallet(@alice.id).balance
    assert_equal "-0.05", R::Reports.portfolio(@alice.id)[:realized_pnl]
    asset.update!(quote: quote("110"))
    result = R::Exchange.submit(actor: @alice, instrument_id: asset.id, side: "close", quantity: "1", leverage: 5, request_id: "order-close")
    assert_equal "filled", result["status"]
    assert_equal "1009.895", R::Account.wallet(@alice.id).balance
    assert_equal 0, R::Position.count
    assert_equal 0, R::Account.where(kind: "escrow").sum(:balance_units).to_i
  end

  def test_zero_payout_liquidation_still_notifies
    fund
    asset = instrument
    result = R::Exchange.submit(actor: @alice, instrument_id: asset.id, side: "long", quantity: "1", leverage: 5, request_id: "order-first")
    fill(asset, R::Order.find(result["order_id"]))
    asset.update!(quote: quote("70"))
    R::Exchange.process(asset.id)
    assert_equal 0, R::Position.count
    assert_equal "979.95", R::Account.wallet(@alice.id).balance
    assert_equal "-20.05", R::Reports.portfolio(@alice.id)[:realized_pnl]
    event = R::Event.find_by!(kind: "stock_liquidated")
    assert_equal "0", event.payload["amount"]
    R::NotificationDelivery.deliver(event)
    assert_equal "/rsc/market?instrument_id=#{asset.id}&order_id=#{R::Order.last.id}#rsc-order-#{R::Order.last.id}", Notification.find(event.reload.notification_id).data_hash["rsc_path"]
    R::Exchange.process(asset.id)
    assert_equal 1, R::Event.where(kind: "stock_liquidated").count
  end

  def test_old_source_quote_cannot_fill_and_expiry_refunds_frozen_wallet
    fund
    asset = instrument
    asset.update!(quote: asset.quote.merge("delay_seconds" => 120))
    result = R::Exchange.submit(actor: @alice, instrument_id: asset.id, side: "long", quantity: "1", leverage: 1, request_id: "order-first")
    order = R::Order.find(result["order_id"])
    order.update!(execute_at: 1.second.ago)
    R::Exchange.process(asset.id)
    assert_equal "pending", order.reload.status
    R::Account.wallet(@alice.id).update!(status: "frozen")
    order.update!(expires_at: 1.second.ago)
    R::Exchange.process(asset.id)
    assert_equal "expired", order.reload.status
    assert_equal "1000", R::Account.wallet(@alice.id).balance
  end

  def test_order_cancel_is_idempotent_and_owned
    fund
    asset = instrument
    asset.update!(quote: asset.quote.merge("delay_seconds" => 120))
    result = R::Exchange.submit(actor: @alice, instrument_id: asset.id, side: "short", quantity: "1", leverage: 2, request_id: "order-first")
    assert_raises(ActiveRecord::RecordNotFound) { R::Exchange.cancel(actor: @bob, order_id: result["order_id"], request_id: "cancel-other") }
    args = { actor: @alice, order_id: result["order_id"], request_id: "cancel-first" }
    R::Exchange.cancel(**args)
    assert R::Exchange.cancel(**args)["replayed"]
    assert_equal "1000", R::Account.wallet(@alice.id).balance
  end

  def test_stop_loss_and_take_profit_are_server_side
    fund
    asset = instrument
    result = R::Exchange.submit(actor: @alice, instrument_id: asset.id, side: "short", quantity: "1", leverage: 2, request_id: "order-first")
    fill(asset, R::Order.find(result["order_id"]))
    position = R::Position.first
    R::Exchange.protect(actor: @alice, position_id: position.id, take_profit: "90", stop_loss: "105", request_id: "protection-first")
    asset.update!(quote: quote("89"))
    R::Exchange.process(asset.id)
    assert_equal 0, R::Position.count
    assert R::Event.exists?(kind: "stock_take_profit")
    assert_equal "1010.9055", R::Account.wallet(@alice.id).balance
  end

  def test_daily_reward_uses_forum_visits_and_is_idempotent
    day = (Time.current.utc + 8.hours).to_date - 1
    UserVisit.find_or_create_by!(user_id: @alice.id, visited_at: day) { |visit| visit.posts_read = 1; visit.time_read = 10 }
    R::Rewards.pay(day.iso8601)
    first = R::Account.wallet(@alice.id).balance
    assert_equal "1", first
    R::Rewards.pay(day.iso8601)
    assert_equal first, R::Account.wallet(@alice.id).balance
    assert_equal 1, R::Event.where(kind: "daily_reward", recipient_user_id: @alice.id).count
  end

  def test_http_state_hides_other_users_financial_records
    fund(@alice, "10")
    fund(@bob, "70")
    key = ApiKey.create!(user_id: @alice.id, created_by_id: @admin.id, description: "trial test")
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "rsc.test"
    session.https!
    session.get "/rsc/state.json", headers: { "Api-Key" => key.key, "Api-Username" => @alice.username }
    assert_equal 200, session.response.status, session.response.body
    state = JSON.parse(session.response.body)
    assert_equal "10", state.dig("wallet", "balance")
    assert_equal 1, state.fetch("entries").size
    SiteSetting.rsc_native_trial_enabled = false
    session.get "/rsc/state.json", headers: { "Api-Key" => key.key, "Api-Username" => @alice.username }
    assert_equal 403, session.response.status
  end
  def test_price_guard_rejects_order_without_charging_and_stale_quotes_cannot_trade
    fund
    asset = instrument
    asset.update!(quote: asset.quote.merge("delay_seconds" => 120))
    result = R::Exchange.submit(actor: @alice, instrument_id: asset.id, side: "long", quantity: "1", leverage: 5, request_id: "order-first")
    order = R::Order.find(result["order_id"])
    order.update!(created_at: 6.minutes.ago, execute_at: 1.second.ago)
    asset.update!(quote: quote("106"))
    R::Exchange.process(asset.id)
    assert_equal "rejected", order.reload.status
    assert_equal "1000", R::Account.wallet(@alice.id).balance
    asset.update!(quote: quote("100").merge("received_at" => 3.minutes.ago.iso8601))
    error = assert_raises(R::Error) { R::Exchange.submit(actor: @alice, instrument_id: asset.id, side: "long", quantity: "1", leverage: 5, request_id: "order-stale") }
    assert_equal "quote_stale", error.code
  end

  def test_concurrent_packet_claims_do_not_duplicate_and_notify_sender
    fund(@alice, "10")
    result = R::RedPackets.create(actor: @alice, mode: "fixed", count: 1, amount: "2", request_id: "packet-create")
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          begin
            R::RedPackets.claim(actor: User.find(@bob.id), token: result["token"], request_id: "packet-claim-#{index}")
            :claimed
          rescue R::Error => error
            error.code
          end
        end
      end
    end
    outcomes = threads.map(&:value)
    assert_equal 1, outcomes.count(:claimed)
    assert_equal "2", R::Account.wallet(@bob.id).balance
    assert_equal 1, R::PacketClaim.count
    event = R::Event.find_by!(kind: "red_packet_claimed_by")
    assert_equal @alice.id, event.recipient_user_id
    assert_equal @bob.id, event.payload["actor_user_id"]
    R::NotificationDelivery.deliver(event)
    assert event.reload.delivered_at
  end

  def test_portfolio_summary_uses_last_quote_without_enabling_execution
    fund
    asset = instrument
    result = R::Exchange.submit(actor: @alice, instrument_id: asset.id, side: "long", quantity: "1", leverage: 5, request_id: "summary-order")
    fill(asset, R::Order.find(result["order_id"]))
    asset.update!(quote: quote("90"))
    key = ApiKey.create!(user_id: @alice.id, created_by_id: @admin.id, description: "portfolio summary")
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "rsc.test"
    session.https!
    headers = { "Api-Key" => key.key, "Api-Username" => @alice.username }
    session.get "/rsc/state.json", headers: headers
    assert_equal 200, session.response.status, session.response.body
    portfolio = JSON.parse(session.response.body).fetch("portfolio")
    assert_equal "20", portfolio["margin"]
    assert_equal "-10", portfolio["pnl"]
    assert_equal "10", portfolio["equity"]
    asset.update!(quote: quote("90").merge("received_at" => 3.minutes.ago.iso8601))
    session.get "/rsc/state.json", headers: headers
    assert_equal 200, session.response.status, session.response.body
    portfolio = JSON.parse(session.response.body).fetch("portfolio")
    assert_equal "-10", portfolio["pnl"]
    assert_equal "10", portfolio["equity"]
    assert_raises(R::Error) { R::Exchange.price!(asset) }
    asset.update!(quote: {})
    session.get "/rsc/state.json", headers: headers
    portfolio = JSON.parse(session.response.body).fetch("portfolio")
    assert_equal "0", portfolio["pnl"]
    assert_equal "20", portfolio["equity"]
  end

end
