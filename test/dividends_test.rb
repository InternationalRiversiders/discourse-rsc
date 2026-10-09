# frozen_string_literal: true
require '/rsc/test/trading_policy_test'
class DividendsTest < TradingPolicyTest
  TradingPolicyTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  def setup
    super
    SiteSetting.rsc_dividends_enabled = true
  end
  def stock
    item=instrument
    item.update!(currency:'USD',asset_type:'stock',fee_bps:0,minimum_units:R::Amount.parse('0.01'),step_units:R::Amount.parse('0.01'))
    item
  end
  def schedule(item, amount='2', approve:true)
    result=R::Dividends.create(actor:@admin,instrument_id:item.id,ex_date:'2026-10-09',amount:amount,
      source_url:'https://example.com/dividend',reason:'Verified ordinary USD cash dividend',request_id:SecureRandom.uuid)
    event=R::Dividend.find(result['id'])
    R::Dividends.review(actor:@admin,id:event.id,decision:'approved',version:event.lock_version,request_id:SecureRandom.uuid) if approve
    event.reload
  end
  def open_stock(item, side:'long', quantity:'1', leverage:10, user:@alice)
    R::Exchange.submit(actor:user,instrument_id:item.id,side:side,quantity:quantity,leverage:leverage,request_id:SecureRandom.uuid)
    R::Position.find_by!(user_id:user.id,instrument_id:item.id)
  end
  def after_ex(item, price='98')
    travel_to(Time.utc(2026,10,9,13,31))
    item.update!(quote:quote(price).merge('bid'=>price,'ask'=>price))
  end
  def before_ex
    travel_to(Time.utc(2026,10,8,15))
    yield
  ensure
    travel_back
  end
  def test_dividend_long_accrual_prevents_ex_date_liquidation_and_settles_once
    before_ex do
      fund;item=stock;position=open_stock(item);event=schedule(item,'20')
      before=R::Account.wallet(@alice.id).balance
      after_ex(item,'80');R::Exchange.process(item.id)
      assert_equal 'applied',event.reload.status
      assert_equal R::Amount.parse('20'),position.reload.dividend_units
      assert_equal '10',R::Views.position(position)[:equity]
      assert_equal '72.5',R::Risk.liquidation(position)
      assert_equal '80',R::Amount.format(R::TradingRules.break_even(position,0))
      assert_equal before,R::Account.wallet(@alice.id).balance
      2.times { R::Exchange.process(item.id) }
      assert_equal 1,R::DividendEntry.count
      result=R::Exchange.submit(actor:@alice,instrument_id:item.id,side:'close',quantity:'1',leverage:10,request_id:'dividend-close-once')
      assert_equal '20',R::Order.find(result['order_id']).details['dividend']
      assert_equal '0',R::Order.find(result['order_id']).details['pnl']
      assert_equal '1000',R::Account.wallet(@alice.id).balance
      assert_equal 0,R::Entry.sum(:units)
      assert_equal 0,R::Position.count
      assert_equal 1,R::Dividends.history(@alice.id).size
    end
  end
  def test_dividend_short_debit_can_exceed_margin_without_overdrawing_wallet
    before_ex do
      fund;item=stock;position=open_stock(item,side:'short');schedule(item,'20')
      after_ex(item,'80');R::Exchange.process(item.id)
      assert_equal R::Amount.parse('20')*-1,position.reload.dividend_units
      assert_equal '10',R::Views.position(position)[:equity]
      assert_equal '87.5',R::Risk.liquidation(position)
      assert_equal '80',R::Amount.format(R::TradingRules.break_even(position,0))
      R::Exchange.submit(actor:@alice,instrument_id:item.id,side:'close',quantity:'1',leverage:10,request_id:SecureRandom.uuid)
      assert_equal '1000',R::Account.wallet(@alice.id).balance
      assert_equal 0,R::Entry.sum(:units)
    end
  end
  def test_dividend_partial_closes_preserve_signed_rounding_remainder
    %w[long short].each do |side|
      before_ex do
        fund;item=stock;item.update!(symbol:side);position=open_stock(item,side:side,quantity:'3');schedule(item,'0.33333333')
        after_ex(item,'99.66666667');R::Exchange.process(item.id)
        total=position.reload.dividend_units.to_i
        chunks=[]
        3.times do
          result=R::Exchange.submit(actor:@alice,instrument_id:item.id,side:'close',quantity:'1',leverage:10,request_id:SecureRandom.uuid)
          chunks << (BigDecimal(R::Order.find(result['order_id']).details['dividend'])*R::Amount::UNIT).to_i
        end
        assert_equal total,chunks.sum
        assert_equal 0,R::Entry.sum(:units)
      end
    end
  end
  def test_dividend_adjustment_runs_before_new_open_and_no_late_entitlement
    before_ex do
      fund;item=stock;schedule(item)
      after_ex(item)
      position=open_stock(item)
      assert_equal 0,position.dividend_units
      assert_equal 'applied',R::Dividend.first.status
      assert_equal 0,R::DividendEntry.count
    end
  end
  def test_dividend_pending_orders_are_refunded_before_the_ex_date_fill
    before_ex do
      fund;item=stock;item.update!(quote:quote('100').merge('delay_seconds'=>900))
      result=R::Exchange.submit(actor:@alice,instrument_id:item.id,side:'long',quantity:'1',leverage:10,request_id:SecureRandom.uuid)
      R::Order.find(result['order_id']).update!(expires_at:Time.utc(2026,10,9,14))
      schedule(item);after_ex(item);R::Exchange.process(item.id)
      order=R::Order.find(result['order_id'])
      assert_equal 'canceled',order.status
      assert_equal 'dividend_adjustment',order.details['error']
      assert_equal '1000',R::Account.wallet(@alice.id).balance
      assert_equal 0,R::Position.count
    end
  end
  def test_dividend_stale_pre_ex_quote_blocks_closing_without_granting_cash
    before_ex do
      fund;item=stock;position=open_stock(item);event=schedule(item)
      after_ex(item)
      item.update!(quote:quote('100').merge('source_time'=>Time.utc(2026,10,9,13,29,30).iso8601,'delay_seconds'=>900))
      assert_equal 'dividend_pending',assert_raises(R::Error) { R::Exchange.submit(actor:@alice,instrument_id:item.id,side:'close',quantity:'1',leverage:10,request_id:SecureRandom.uuid) }.code
      assert_equal "dividend_pending",assert_raises(R::Error) { R::Exchange.process(item.id) }.code
      assert_equal 0,position.reload.dividend_units
      assert_equal 'approved',event.reload.status
      assert_equal 0,R::DividendEntry.count
    end
  end
  def test_dividend_protection_prices_move_with_ex_date_and_no_spurious_trigger
    before_ex do
      fund;item=stock;position=open_stock(item)
      position.update!(take_profit_units:R::Amount.parse('105'),stop_loss_units:R::Amount.parse('95'))
      schedule(item,'10');after_ex(item,'90');R::Exchange.process(item.id)
      assert_equal R::Amount.parse('95'),position.reload.take_profit_units
      assert_equal R::Amount.parse('85'),position.stop_loss_units
      assert_equal 0,R::Order.where(side:'close').count
      R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:'96',stop_loss:'86',request_id:SecureRandom.uuid)
      assert_equal R::Amount.parse('96'),position.reload.take_profit_units
    end
  end
  def test_dividend_frozen_wallet_still_accrues_and_disable_does_not_cancel_obligation
    before_ex do
      fund;item=stock;position=open_stock(item);schedule(item)
      R::Account.wallet(@alice.id).update!(status:'frozen')
      SiteSetting.rsc_dividends_enabled=false
      after_ex(item);R::Exchange.process(item.id)
      assert_equal R::Amount.parse('2'),position.reload.dividend_units
      assert_equal 1,R::DividendEntry.count
    end
  end
  def test_dividend_draft_and_canceled_events_never_pay
    before_ex do
      fund;item=stock;position=open_stock(item);event=schedule(item,approve:false)
      R::Dividends.review(actor:@admin,id:event.id,decision:'canceled',version:event.lock_version,request_id:SecureRandom.uuid)
      after_ex(item);R::Exchange.process(item.id)
      assert_equal 0,position.reload.dividend_units
      assert_equal 0,R::DividendEntry.count
    end
  end
  def test_dividend_permissions_scope_stale_review_and_past_date
    before_ex do
      item=stock;event=schedule(item,approve:false)
      assert_equal 'admin_required',assert_raises(R::Error) { R::Dividends.review(actor:@alice,id:event.id,decision:'approved',version:event.lock_version,request_id:SecureRandom.uuid) }.code
      assert_equal 'dividend_locked',assert_raises(R::Error) { R::Dividends.review(actor:@admin,id:event.id,decision:'approved',version:event.lock_version+1,request_id:SecureRandom.uuid) }.code
      item.update!(category:'crypto')
      assert_equal 'dividend_ineligible',assert_raises(R::Error) { R::Dividends.review(actor:@admin,id:event.id,decision:'approved',version:event.lock_version,request_id:SecureRandom.uuid) }.code
      item.update!(category:'us');after_ex(item)
      assert_equal 'dividend_too_late',assert_raises(R::Error) { R::Dividends.review(actor:@admin,id:event.id,decision:'approved',version:event.lock_version,request_id:SecureRandom.uuid) }.code
      assert_equal 0,R::DividendEntry.count
    end
  end
  def test_dividend_add_after_ex_preserves_original_accrual_and_total_close
    before_ex do
      fund;item=stock;position=open_stock(item);schedule(item)
      after_ex(item);R::Exchange.process(item.id)
      open_stock(item)
      assert_equal R::Amount.parse('2'),position.reload.dividend_units
      assert_equal R::Amount.parse('99'),position.average_units
      R::Exchange.submit(actor:@alice,instrument_id:item.id,side:'close',quantity:'2',leverage:10,request_id:SecureRandom.uuid)
      assert_equal '1000',R::Account.wallet(@alice.id).balance
    end
  end
  def test_dividend_failed_transaction_rolls_back_accrual_and_retry_is_safe
    before_ex do
      fund;item=stock;position=open_stock(item);event=schedule(item)
      after_ex(item)
      assert_raises(R::Error) { R::Exchange.submit(actor:@alice,instrument_id:item.id,side:'close',quantity:'100',leverage:10,request_id:SecureRandom.uuid) }
      assert_equal 0,R::DividendEntry.count
      assert_equal 0,position.reload.dividend_units
      assert_equal 'approved',event.reload.status
      R::Exchange.process(item.id)
      assert_equal 1,R::DividendEntry.count
    end
  end
  def test_dividend_entire_batch_rolls_back_if_any_holding_is_inconsistent
    before_ex do
      fund;fund(@bob);item=stock;first=open_stock(item);second=open_stock(item,user:@bob);event=schedule(item)
      after_ex(item)
      second.update!(created_at:Time.current)
      assert_equal 'dividend_inconsistent',assert_raises(R::Error) { R::Exchange.process(item.id) }.code
      assert_equal 0,first.reload.dividend_units
      assert_equal 0,R::DividendEntry.count
      assert_equal 'approved',event.reload.status
    end
  end
  def test_dividend_rejects_invalid_sources_and_weekends_and_duplicates
    before_ex do
      item=stock
      base={actor:@admin,instrument_id:item.id,ex_date:'2026-10-09',amount:'2',source_url:'https://example.com/news',reason:'Verified announcement'}
      [{source_url:'javascript:alert(1)'},{source_url:'https://user:pass@example.com/'},{ex_date:'2026-10-10'},{amount:'0'},{amount:'1.123456789'}].each do |invalid|
        assert_raises(R::Error) { R::Dividends.create(**base.merge(invalid),request_id:SecureRandom.uuid) }
      end
      schedule(item)
      assert_equal 'dividend_locked',assert_raises(R::Error) { R::Dividends.create(**base,request_id:SecureRandom.uuid) }.code
      assert_equal 1,R::Dividend.count
    end
  end
  def test_dividend_preview_review_twice_and_dst_cutoff
    before_ex do
      item=stock;event=schedule(item,approve:false)
      assert_equal Time.utc(2026,10,9,13,30),event.effective_at
      args={actor:@admin,id:event.id,decision:'approved',version:event.lock_version,request_id:'same-dividend-review'}
      R::Dividends.review(**args)
      assert R::Dividends.review(**args)['replayed']
      result=R::Dividends.create(actor:@admin,instrument_id:item.id,ex_date:'2026-11-09',amount:'2',source_url:'https://example.com/news',reason:'Verified',request_id:SecureRandom.uuid)
      assert_equal Time.utc(2026,11,9,14,30),R::Dividend.find(result['id']).effective_at
    end
  end

  def test_dividend_concurrent_workers_accrue_only_once
    before_ex do
      fund;item=stock;position=open_stock(item);schedule(item)
      after_ex(item)
      threads=2.times.map do
        Thread.new { ActiveRecord::Base.connection_pool.with_connection { R::Exchange.process(item.id) } }
      end
      threads.each(&:value)
      assert_equal 1,R::DividendEntry.count
      assert_equal R::Amount.parse('2'),position.reload.dividend_units
    end
  end
  def test_dividend_changed_instrument_scope_cannot_apply
    before_ex do
      fund;item=stock;position=open_stock(item);event=schedule(item)
      after_ex(item);item.update!(currency:'EUR')
      assert_equal 'dividend_ineligible',assert_raises(R::Error) { R::Exchange.process(item.id) }.code
      assert_equal 0,R::DividendEntry.count
      assert_equal 0,position.reload.dividend_units
      assert_equal 'approved',event.reload.status
    end
  end

end
