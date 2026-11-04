# frozen_string_literal: true
require '/rsc/test/automatic_protection_fallback_test'

class ExecutionLifecycleTest < AutomaticProtectionFallbackTest
  AutomaticProtectionFallbackTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def exposed_position(side: 'long', leverage: 100)
    activity; fund
    item=live_fx(G.accepted(observation('1'),'continuous'))
    opening=submit(item,side:side,quantity:'100',leverage:leverage)
    assert_equal 'filled',opening.status
    position=R::Position.find_by!(instrument_id:item.id,user_id:@alice.id)
    assert_nil position.take_profit_units
    assert_nil position.stop_loss_units
    stale=item.quote.merge('source_time'=>5.minutes.ago.iso8601,'received_at'=>5.minutes.ago.iso8601)
    item.update!(quote:stale,synced_at:5.minutes.ago)
    [item,position,stale]
  end

  def review_samples(item, count: 3)
    count.times do |n|
      Discourse.redis.del('rsc:fx-fallback:slot',"rsc:fx-review:#{item.id}")
      yield n
      travel 60.seconds if n<count-1
    end
  end

  [['long',100,'0.992'],['short',100,'1.008'],['long',1,'0.24']].each do |side,leverage,price|
    define_method("test_#{side}_#{leverage}x_liquidation_without_stops_uses_reviewed_primary") do
      travel_to(Time.utc(2026,11,3,12)) do
        item,position,stale=exposed_position(side:side,leverage:leverage)
        with_backup_feed(-> { observation(price) },R::Error.new('provider_daily_limit')) do |calls|
          review_samples(item) do |n|
            poll
            assert R::Position.exists?(position.id) if n<2
          end
          refute R::Position.exists?(position.id)
          closing=R::Order.where(side:'close').sole
          assert_equal 'stock_liquidated',closing.details['reason']
          assert_equal 'yahoo',closing.details.dig('execution_quote','source')
          assert_empty calls
          assert_equal 0,B.report[:total_reserved]
          before=R::Account.wallet(@alice.id).balance
          poll;R::Exchange.process(item.id)
          assert_equal before,R::Account.wallet(@alice.id).balance
          assert_equal 1,R::Order.where(side:'close').count
          assert_equal 0,R::Entry.sum(:units)
        end
      end
    end
  end

  def test_added_margin_is_rechecked_before_liquidation_at_confirmed_price
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=exposed_position
      with_backup_feed(-> { observation('0.992') },R::Error.new('provider_daily_limit')) do |calls|
        review_samples(item) do |n|
          R::Exchange.add_margin(actor:@alice,position_id:position.id,amount:'1',request_id:SecureRandom.uuid) if n==2
          poll
        end
        assert_empty calls
        assert R::Position.exists?(position.id)
        assert_equal R::Amount.parse('2'),position.reload.margin_units
        assert_equal 0,R::Order.where(side:'close').count
        assert_equal 0,R::Entry.sum(:units)
      end
    end
  end

  def test_general_poll_checks_liquidation_and_refunds_expired_orders_without_a_price
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=exposed_position
      with_backup_feed(-> { observation('0.992') },R::Error.new('provider_daily_limit')) do |calls|
        review_samples(item) { R::MarketData.sync { |id| R::Exchange.process(id) } }
        refute R::Position.exists?(position.id)
        assert_equal 'stock_liquidated',R::Order.where(side:'close').sole.details['reason']
        assert_empty calls
      end
      item.update!(quote:G.accepted(observation('1'),'continuous'),provider_error:nil)
      SiteSetting.rsc_market_data_enabled=false
      queued=legacy_pending(item,quantity:'10')
      assert_operator queued.reserved_units,:>,0
      travel 31.minutes
      SiteSetting.rsc_market_data_enabled=true
      item.update!(quote:stale,provider_error:nil,synced_at:5.minutes.ago)
      before=R::Account.wallet(@alice.id).balance_units
      reserved=queued.reserved_units
      with_feeds(R::Error.new('provider_unavailable'),R::Error.new('provider_unavailable')) do |calls|
        R::MarketData.sync { |id| R::Exchange.process(id) }
        assert_equal 0,calls[:backup]
      end
      assert_equal 'expired',queued.reload.status
      assert_equal before+reserved,R::Account.wallet(@alice.id).balance_units
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_daily_limit_cannot_cause_a_stale_price_liquidation
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=exposed_position
      item.update!(quote:stale.merge('price'=>'0.1'))
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",750)
      with_backup_feed(stale,'0.1') do |calls|
        poll
        assert_empty calls
        assert R::Position.exists?(position.id)
        assert_equal 0,R::Order.where(side:'close').count
      end
    end
  end

  def test_empty_catalog_and_frozen_positions_do_not_create_automatic_demand
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=exposed_position
      assert R::ExecutionDemand.automatic?(item.id)
      R::Account.wallet(@alice.id).update!(status:'frozen')
      refute R::ExecutionDemand.automatic?(item.id)
      with_backup_feed(stale,'0.992') { |calls| poll;assert_empty calls }
      assert R::Position.exists?(position.id)
      item2=forex('FX:NOK')
      refute R::ExecutionDemand.automatic?(item2.id)
    end
  end

  def test_abandoned_browsing_and_position_reviews_leave_backup_queue
    travel_to(Time.utc(2026,11,3,12)) do
      unused=forex('FX:NOK');unused.update!(provider:'yahoo',provider_symbol:'NOK=X',quote:observation('1'))
      accept(unused,'1.002')
      R::ForexReviewQueue.enqueue(unused.id)
      assert R::ForexReviewQueue.turn?(unused.id)
      item,position,_=exposed_position
      accept(item,'1.002')
      assert G.pending?(item.reload.quote)
      assert_nil R::ForexReviewQueue.next_instrument
      assert_equal 0,R::ForexReviewQueue.claim
      assert R::Position.exists?(position.id)
    end
  end

  def test_known_invalid_submissions_do_not_fetch_and_state_is_checked_again_after_refresh
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,_=exposed_position
      original=R::MarketData.method(:refresh_if_needed)
      R::MarketData.define_singleton_method(:refresh_if_needed){|*| raise 'Invalid request reached provider'}
      [['short','1','position_conflict'],['close','101','position_unavailable'],['long','0.001','invalid_quantity']].each do |side,quantity,code|
        assert_equal code,assert_raises(R::Error){submit(item,side:side,quantity:quantity)}.code
      end
      R::Account.wallet(@alice.id).update!(status:'frozen')
      assert_equal 'wallet_frozen',assert_raises(R::Error){submit(item,quantity:'1')}.code
      R::Account.wallet(@alice.id).update!(status:'active')
      R::MarketData.define_singleton_method(:refresh_if_needed) do |id,**|
        R::Account.wallet(position.user_id).update!(status:'frozen')
        R::Instrument.find(id)
      end
      assert_equal 'wallet_frozen',assert_raises(R::Error){submit(item,side:'close',quantity:'1')}.code
      assert_equal 0,R::Order.where(side:'close').count
      assert_equal 0,R::Entry.sum(:units)
    ensure
      R::MarketData.define_singleton_method(:refresh_if_needed,original) if original
    end
  end

  def test_liquidation_precedes_stops_and_uses_current_collateral
    item,position,_=exposed_position
    position.update!(stop_loss_units:R::Amount.parse('0.999'),take_profit_units:R::Amount.parse('1.01'))
    assert_equal 'stock_liquidated',R::Exchange.automatic_close_reason(position,R::Amount.parse('0.992'))
    assert_equal 'stock_stop_loss',R::Exchange.automatic_close_reason(position,R::Amount.parse('0.999'))
    assert_equal 'stock_take_profit',R::Exchange.automatic_close_reason(position,R::Amount.parse('1.01'))
    assert_nil R::Exchange.automatic_close_reason(position,R::Amount.parse('1'))
  end
end
