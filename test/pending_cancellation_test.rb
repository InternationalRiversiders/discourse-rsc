# frozen_string_literal: true
require '/rsc/test/business_test'

class PendingCancellationTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def waiting_order
    fund
    item = instrument
    item.update!(metadata: { 'trading_hours' => '24/7' })
    order = legacy_pending_order(item)
    order.update!(created_at: 16.minutes.ago, execute_at: 1.second.ago, expires_at: 10.minutes.from_now)
    [item, order]
  end

  def cancel(order, request_id: SecureRandom.uuid, actor: @alice)
    R::Exchange.cancel(actor: actor, order_id: order.id, request_id: request_id)
  end

  def assert_refunded(order)
    assert_equal 'canceled', order.reload.status
    assert_equal 0, order.reserved_units
    assert_equal '1000', R::Account.wallet(@alice.id).balance
    assert_equal 0, R::Position.count
    assert_equal 1, R::Journal.where(operation: 'stock_refund').count
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_pending_cancellation_after_old_window_refunds_and_never_fills
    item, order = waiting_order
    view = R::Views.order(order)
    assert view[:can_cancel]
    assert_equal order.created_at, view[:cancel_at]
    assert_nil view[:cancel_until]
    assert_operator order.reserved_units, :>, 0
    cancel(order)
    R::Exchange.process(item.id)
    assert_refunded(order)
    refute R::Views.order(order)[:can_cancel]
  end

  def test_pending_cancellation_is_owned_and_idempotent
    _, order = waiting_order
    assert_raises(ActiveRecord::RecordNotFound) { cancel(order, actor: @bob) }
    assert_equal 'pending', order.reload.status
    key = SecureRandom.uuid
    cancel(order, request_id: key)
    assert cancel(order, request_id: key)['replayed']
    error = assert_raises(R::Error) { cancel(order) }
    assert_equal 'order_not_pending', error.code
    assert_refunded(order)
  end

  def test_pending_cancellation_cannot_refund_a_fill
    item, order = waiting_order
    R::Exchange.process(item.id)
    assert_equal 'filled', order.reload.status
    balance = R::Account.wallet(@alice.id).balance
    error = assert_raises(R::Error) { cancel(order) }
    assert_equal 'order_not_pending', error.code
    assert_equal balance, R::Account.wallet(@alice.id).balance
    assert_equal 0, R::Journal.where(operation: 'stock_refund').count
    refute R::Views.order(order)[:can_cancel]
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_pending_cancellation_races_execution_without_double_settlement
    item, order = waiting_order
    ready = Queue.new
    start = Queue.new
    workers = [
      -> { R::Exchange.process(item.id); :processed },
      -> { cancel(order); :canceled }
    ].map do |work|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          begin
            work.call
          rescue R::Error => error
            error.code
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = workers.map(&:value)
    assert_includes results, :processed
    assert_equal 0, order.reload.reserved_units
    if order.status == 'canceled'
      assert_includes results, :canceled
      assert_refunded(order)
    else
      assert_equal 'filled', order.status
      assert_includes results, 'order_not_pending'
      assert_equal 1, R::Position.count
      assert_equal 0, R::Journal.where(operation: 'stock_refund').count
      assert_equal 0, R::Entry.sum(:units)
    end
  end

  def test_pending_cancellation_of_close_keeps_the_position
    item, opening = waiting_order
    R::Exchange.process(item.id)
    assert_equal 'filled', opening.reload.status
    position = R::Position.first
    before_position = position.attributes
    before_balance = R::Account.wallet(@alice.id).balance
    closing = legacy_pending_order(item, side: 'close')
    closing.update!(created_at: 16.minutes.ago, execute_at: 1.second.ago)
    assert R::Views.order(closing)[:can_cancel]
    cancel(closing)
    R::Exchange.process(item.id)
    assert_equal 'canceled', closing.reload.status
    assert_equal before_position, position.reload.attributes
    assert_equal before_balance, R::Account.wallet(@alice.id).balance
    assert_equal 0, R::Entry.sum(:units)
  end
end
