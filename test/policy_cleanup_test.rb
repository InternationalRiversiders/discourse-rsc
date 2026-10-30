# frozen_string_literal: true
require_relative 'trading_policy_test'
require_relative 'native_adaptation_test'

class PolicyCleanupTest < TradingPolicyTest
  TradingPolicyTest.public_instance_methods.grep(/^test_/).each { |name| undef_method name }

  def test_close_ignores_ten_pending_opening_orders
    fund
    item = coin('HOLDING')
    opened = submit(item)
    opened.update!(created_at: 1.second.ago)
    advance_quote(item)
    10.times do |i|
      other = coin("PENDING#{i}")
      R::Order.create!(user_id: @alice.id, instrument_id: other.id, side: 'long', leverage: 1,
        status: 'pending', quantity_units: R::Amount::UNIT, execute_at: Time.current, expires_at: 1.hour.from_now, details: {})
    end
    assert_equal 'filled', submit(item, side: 'close').status
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_cancel_open_and_close_is_explicit_atomic_and_replay_safe
    fund
    item = coin
    opened = submit(item)
    opened.update!(created_at: 1.second.ago)
    advance_quote(item)
    pending = legacy_pending_order(item,leverage:10)
    before = R::Account.wallet(@alice.id).balance
    assert_equal 'order_pending', assert_raises(R::Error) { submit(item, side: 'close') }.code
    assert_equal 'position_unavailable', assert_raises(R::Error) {
      R::Exchange.submit(actor: @alice, instrument_id: item.id, side: 'close', quantity: '2', leverage: 10,
        cancel_pending: true, request_id: SecureRandom.uuid)
    }.code
    assert_equal 'pending', pending.reload.status
    assert_equal before, R::Account.wallet(@alice.id).balance
    input = {actor: @alice, instrument_id: item.id, side: 'close', quantity: '1', leverage: 10,
      cancel_pending: true, request_id: SecureRandom.uuid}
    result = R::Exchange.submit(**input)
    assert_equal 'canceled', pending.reload.status
    assert R::Exchange.submit(**input)['replayed']
    closing = R::Order.find(result['order_id'])
    closing.update!(created_at: 1.second.ago)
    advance_quote(item)
    assert_equal 'filled', closing.reload.status
    assert_equal 0, R::Position.count
    assert_equal 0, R::Account.where(kind: 'escrow').sum(:balance_units)
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_wallet_daily_limits_can_be_disabled_or_enabled_independently
    fund
    SiteSetting.rsc_daily_outgoing_count = 0
    SiteSetting.rsc_daily_outgoing_amount = '0'
    21.times { R::Wallet.transfer(actor: @alice, recipient: @bob, amount: '20', request_id: SecureRandom.uuid) }
    assert_equal '420', R::Account.wallet(@bob.id).balance
    SiteSetting.rsc_daily_outgoing_count = 21
    assert_equal 'daily_count_limit', assert_raises(R::Error) {
      R::Wallet.transfer(actor: @alice, recipient: @bob, amount: '1', request_id: SecureRandom.uuid)
    }.code
    SiteSetting.rsc_daily_outgoing_count = 0
    SiteSetting.rsc_daily_outgoing_amount = '420'
    assert_equal 'daily_amount_limit', assert_raises(R::Error) {
      R::Wallet.transfer(actor: @alice, recipient: @bob, amount: '1', request_id: SecureRandom.uuid)
    }.code
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_large_packet_still_respects_wallet_and_refunds_once
    fund
    SiteSetting.rsc_daily_outgoing_count = 0
    SiteSetting.rsc_daily_outgoing_amount = '0'
    packet = R::RedPackets.create(actor: @alice, mode: 'fixed', count: 2, amount: '200', request_id: SecureRandom.uuid)
    assert_equal '400', packet['total']
    claim = {actor: @bob, token: packet['token'], request_id: SecureRandom.uuid}
    assert_equal '200', R::RedPackets.claim(**claim)['amount']
    assert R::RedPackets.claim(**claim)['replayed']
    R::RedPackets.close(actor: @alice, token: packet['token'], request_id: SecureRandom.uuid)
    assert_equal '800', R::Account.wallet(@alice.id).balance
    assert_equal 'insufficient_balance', assert_raises(R::Error) {
      R::RedPackets.create(actor: @alice, mode: 'fixed', count: 2, amount: '500', request_id: SecureRandom.uuid)
    }.code
    assert_equal 1, R::Packet.count
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_prediction_withdrawal_refunds_once_and_can_reenter
    fund(@alice, '100')
    game = match
    first = R::Sports.predict(actor: @alice, match_id: game.id, pick: 'home', stake: '20', request_id: SecureRandom.uuid)
    input = {actor: @alice, prediction_id: first['prediction_id'], request_id: SecureRandom.uuid}
    assert_equal '20', R::Sports.cancel(**input)['refunded']
    assert R::Sports.cancel(**input)['replayed']
    assert_equal '100', R::Account.wallet(@alice.id).balance
    assert_equal 'withdrawn', R::Prediction.first.status
    assert_equal 0, R::Views.matches(@alice.id).first[:participants]
    R::Sports.predict(actor: @alice, match_id: game.id, prediction_id: first['prediction_id'], pick: 'away', stake: '30', request_id: SecureRandom.uuid)
    assert_equal '70', R::Account.wallet(@alice.id).balance
    assert_equal 'pending', R::Prediction.first.status
    assert_equal 0, R::Prediction.first.payout_units
    # Replaying the previous withdrawal must not withdraw a newly entered stake.
    assert R::Sports.cancel(**input)['replayed']
    assert_equal '70', R::Account.wallet(@alice.id).balance
    game.update!(status: 'finished', result: 'away', confirmed_at: 10.minutes.ago)
    assert_equal 1, R::Sports.settle(game.id)
    assert_equal '160', R::Account.wallet(@alice.id).balance
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_prediction_withdrawal_requires_ownership_and_pre_match_state
    fund(@alice, '100')
    game = match
    row = R::Sports.predict(actor: @alice, match_id: game.id, pick: 'home', stake: '20', request_id: SecureRandom.uuid)
    assert_raises(ActiveRecord::RecordNotFound) { R::Sports.cancel(actor: @bob, prediction_id: row['prediction_id'], request_id: SecureRandom.uuid) }
    game.update!(starts_at: 1.second.ago)
    assert_equal 'match_locked', assert_raises(R::Error) { R::Sports.cancel(actor: @alice, prediction_id: row['prediction_id'], request_id: SecureRandom.uuid) }.code
    assert_equal '80', R::Account.wallet(@alice.id).balance
    game.update!(starts_at: 1.day.from_now)
    R::Account.wallet(@alice.id).update!(status: 'frozen')
    R::Sports.cancel(actor: @alice, prediction_id: row['prediction_id'], request_id: SecureRandom.uuid)
    assert_equal '100', R::Account.wallet(@alice.id).balance
    game.update!(status: 'finished', result: 'home', confirmed_at: 10.minutes.ago)
    assert_equal 0, R::Sports.settle(game.id)
    assert_equal 0, R::Entry.sum(:units)
  end
end
