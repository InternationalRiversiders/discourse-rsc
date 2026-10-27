# frozen_string_literal: true
require '/rsc/test/forex_activity_test'
class ForexExitQueueTest < ForexActivityTest
  ForexActivityTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  def opened
    fund; activity; item=forex('FX:CNY'); submit(item); tick_quote(item); item
  end
  def stale(item)
    item.update!(quote: item.quote.merge('source_time'=>10.minutes.ago.iso8601, 'received_at'=>Time.current.iso8601))
  end
  def test_stale_partial_exit_waits_without_moving_money_and_fills_once_at_fresh_price
    travel_to(Time.utc(2026,10,26,12)) do
      item=opened; stale(item); before=R::Journal.count; balance=R::Account.wallet(@alice.id).balance
      order=submit(item,side:'close',quantity:'40',request_id:'queued-partial-close')
      assert_equal 'pending',order.status
      assert order.details['waiting_quote']; assert_nil order.details['reference_price']
      assert_equal before,R::Journal.count; assert_equal balance,R::Account.wallet(@alice.id).balance
      assert_equal order.id,submit(item,side:'close',quantity:'40',request_id:'queued-partial-close').id
      R::Exchange.process(item.id); assert_equal 'pending',order.reload.status
      assert_equal 'order_pending',assert_raises(R::Error){submit(item,side:'close')}.code
      tick_quote(item,'1.06'); assert_equal 'filled',order.reload.status
      assert_equal '1.06',order.details['price']; assert_equal '2.4',order.details['pnl']
      assert_equal R::Amount.parse('60'),R::Position.first.quantity_units
      R::Exchange.process(item.id); assert_equal before+1,R::Journal.count
      assert_equal 0,R::Entry.sum(:units)
    end
  end
  def test_waiting_exit_can_cancel_later_and_expires_without_settlement
    travel_to(Time.utc(2026,10,26,12)) do
      item=opened;stale(item);order=submit(item,side:'close');travel 2.minutes
      assert R::Views.order(order)[:can_cancel]
      R::Exchange.cancel(actor:@alice,order_id:order.id,request_id:'cancel-waiting-close')
      assert_equal 'canceled',order.reload.status
      order=submit(item,side:'close');before=R::Journal.count;travel 31.minutes
      R::Exchange.process(item.id)
      assert_equal 'expired',order.reload.status;assert_equal before,R::Journal.count
      assert_equal 1,R::Position.count
    end
  end
  def test_stale_exits_still_validate_quantity_position_wallet_and_opening_rules
    travel_to(Time.utc(2026,10,26,12)) do
      item=opened;stale(item)
      assert_equal 'position_unavailable',assert_raises(R::Error){submit(item,side:'close',quantity:'101')}.code
      assert_equal 'invalid_quantity',assert_raises(R::Error){submit(item,side:'close',quantity:'0.001')}.code
      assert_equal 'quote_stale',assert_raises(R::Error){submit(item)}.code
      R::Account.wallet(@alice.id).update!(status:'frozen')
      assert_equal 'wallet_frozen',assert_raises(R::Error){submit(item,side:'close')}.code
      R::Account.wallet(@alice.id).update!(status:'active')
      travel_to(Time.utc(2026,10,31,12))
      assert_equal 'market_closed',assert_raises(R::Error){submit(item,side:'close')}.code
    end
  end
  def test_liquidation_cancels_waiting_exit_and_does_not_close_twice
    travel_to(Time.utc(2026,10,26,12)) do
      item=opened;stale(item);order=submit(item,side:'close')
      tick_quote(item,'0.98')
      assert_equal 'canceled',order.reload.status;assert_empty R::Position.all
      assert_equal 1,R::Order.where(side:'close',status:'filled').count
      assert_equal 0,R::Entry.sum(:units)
    end
  end
  def test_queued_exit_never_closes_a_replacement_position
    travel_to(Time.utc(2026,10,26,12)) do
      item=opened;stale(item);order=submit(item,side:'close')
      p=R::Position.first;attrs=p.attributes.except('id');p.delete;R::Position.create!(attrs)
      tick_quote(item)
      assert_equal 'rejected',order.reload.status
      assert_equal 'position_unavailable',order.details['error']
      assert_equal 1,R::Position.count
    end
  end
end
