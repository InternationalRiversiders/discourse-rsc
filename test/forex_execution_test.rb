# frozen_string_literal: true
require '/rsc/test/forex_activity_test'

class ForexExecutionTest < ForexActivityTest
  ForexActivityTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def test_fx_exit_uses_valid_quote_without_next_tick_and_is_idempotent
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;item=forex
      opening=submit(item);R::Exchange.process(item.id)
      assert_equal 'pending',opening.reload.status
      tick_quote(item)
      travel 30.seconds
      before=R::Journal.count
      close=submit(item,side:'close',quantity:'40',request_id:'fx-fast-exit')
      assert_equal 'filled',close.status
      assert_equal '1',close.details['price']
      assert_equal '60',R::Amount.format(R::Position.first.quantity_units)
      assert_equal close.id,submit(item,side:'close',quantity:'40',request_id:'fx-fast-exit').id
      assert_equal before+1,R::Journal.count
      assert_equal 'immediate',R::MarketListing.rows([item]).first[:close_execution_mode]
      assert_equal 0,R::Entry.sum(:units)
      travel 121.seconds
      waiting=submit(item,side:'close',quantity:'60')
      assert_equal 'pending',waiting.status
      assert waiting.details['waiting_quote']
      R::Exchange.process(item.id)
      assert_equal 'pending',waiting.reload.status
      assert_equal 1,R::Position.count
    end
  end

  def test_fx_exit_preserves_real_source_delay_and_closed_market_checks
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;item=forex;submit(item);tick_quote(item)
      item.update!(quote:quote('1').merge('delay_seconds'=>900,'source_time'=>15.minutes.ago.iso8601))
      close=submit(item,side:'close')
      assert_equal 'pending',close.status
      assert_operator close.execute_at,:>,Time.current
      R::Exchange.process(item.id)
      assert_equal 'pending',close.reload.status
      R::Exchange.cancel(actor:@alice,order_id:close.id,request_id:SecureRandom.uuid)
      item.update!(quote:quote('1').merge('session_end'=>1.second.ago.iso8601))
      assert_equal 'market_closed',assert_raises(R::Error) { submit(item,side:'close') }.code
    end
  end

  def test_existing_pending_fx_close_can_finish_with_valid_pre_submission_quote
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;item=forex;submit(item);tick_quote(item)
      travel 10.seconds
      close=R::Order.create!(user_id:@alice.id,instrument_id:item.id,side:'close',leverage:100,
        status:'pending',quantity_units:R::Amount.parse('100'),execute_at:Time.current,expires_at:30.minutes.from_now,
        details:{'fx_confirmation'=>true,'reference_price'=>'1'})
      R::Exchange.process(item.id)
      assert_equal 'filled',close.reload.status
      assert_equal 0,R::Position.count
    end
  end

  def test_fx_sparse_ticks_do_not_manufacture_spread_but_stock_guard_remains
    item=forex
    item.update!(history:60.times.map{|n|{'at'=>(Time.current-n.minutes).iso8601,'price'=>n.even? ? '1' : '1.01'}})
    price=R::Amount.parse('1')
    10.times do
      assert_equal price,R::Exchange.execution_price(item,'long',price)
      assert_equal price,R::Exchange.execution_price(item,'short',price)
    end
    item.category='us'
    assert_operator R::Exchange.execution_price(item,'long',price),:>,price
    assert_operator R::Exchange.execution_price(item,'short',price),:<,price
  end

  def test_fee_reduction_covers_existing_and_pending_activity_without_rewriting_fees
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;item=forex;opening=submit(item);tick_quote(item)
      before=R::Journal.order(:id).pluck(:id,:metadata)
      old_fee=opening.reload.details['fee']
      pending=submit(item)
      SiteSetting.rsc_forex_activity_fee_bps=0
      assert_equal 0,R::ForexActivity.fee_bps(item,position:R::Position.first)
      tick_quote(item)
      assert_equal '0',pending.reload.details['fee']
      assert_equal 0,pending.details['fee_bps']
      assert_equal 0,entry.fee_bps
      assert_equal old_fee,opening.reload.details['fee']
      assert_equal before,R::Journal.where(id:before.map(&:first)).order(:id).pluck(:id,:metadata)
      closing=submit(item,side:'close',quantity:'100')
      assert_equal '0',closing.details['fee']
      SiteSetting.rsc_forex_activity_ends_at=1.second.ago.iso8601
      closing=submit(item,side:'close',quantity:'100')
      assert_equal '0',closing.details['fee']
      assert_equal -R::Amount.parse(old_fee),entry.realized_units.to_i
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_free_campaign_does_not_discount_pre_activity_positions
    travel_to(Time.utc(2026,10,22,12)) do
      fund;item=forex;submit(item,leverage:5)
      activity;SiteSetting.rsc_forex_activity_fee_bps=0
      assert_equal 5,R::ForexActivity.fee_bps(item,position:R::Position.first)
      close=submit(item,side:'close')
      assert_equal '0.05',close.details['fee']
      assert_empty R::ForexActivity.entries
      opening=submit(item);tick_quote(item)
      assert_equal '0',opening.reload.details['fee']
      assert_equal 0,entry.fee_bps
    end
  end

  def test_fast_queue_targets_exposed_fx_and_preserves_freshness_backoff
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;item=forex;submit(item)
      cold=forex('FX:GBP')
      other=instrument;other.update!(symbol:'STOCK');submit(other,quantity:'1',leverage:1)
      SiteSetting.rsc_market_data_enabled=true
      calls=[];processed=[];original=R::MarketData.method(:refresh_if_needed)
      R::MarketData.define_singleton_method(:refresh_if_needed) { |id,**options| calls << [id,options[:purpose]];R::Instrument.find(id) }
      R::MarketData.sync_forex { |id| processed << id }
      assert_equal [[item.id,:forex_fast]],calls
      assert_equal [item.id],processed
      item.update!(quote:quote('1').merge('received_at'=>10.seconds.ago.iso8601))
      refute R::MarketData.refresh_due?(item,purpose: :forex_fast)
      assert R::MarketData.refresh_due?(item,purpose: :exit)
      item.update!(provider_error:'provider_http_429',synced_at:Time.current)
      refute R::MarketData.refresh_due?(item,purpose: :exit)
      refute R::MarketData.refresh_due?(item,purpose: :forex_fast)
    ensure
      R::MarketData.define_singleton_method(:refresh_if_needed,original) if original
    end
  end
end
