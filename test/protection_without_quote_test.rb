# frozen_string_literal: true
require '/rsc/test/native_adaptation_test'
class ProtectionWithoutQuoteTest < NativeAdaptationTest
  NativeAdaptationTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def protect(position, tp: '120', sl: '90', request_id: SecureRandom.uuid)
    R::Exchange.protect(actor: @alice, position_id: position.id,
      take_profit: tp, stop_loss: sl, request_id: request_id)
  end

  def test_expired_missing_and_quarantined_quotes_do_not_block_save_or_clear
    fund; item=instrument; fill(item, order(item)); position=R::Position.first!
    network=R::MarketData.method(:refresh_if_needed)
    R::MarketData.define_singleton_method(:refresh_if_needed) { |*| raise 'Protection must not fetch prices' }
    snapshots=[quote('80').merge('received_at'=>1.hour.ago.iso8601), {},
      quote('80').merge('verification'=>{'status'=>'pending'})]
    snapshots.each_with_index do |snapshot,index|
      item.update!(category: index==2 ? 'forex' : 'us', quote:snapshot)
      before=[R::Order.count,R::Journal.count,R::Account.wallet(@alice.id).balance]
      result=protect(position)
      assert result['protection_saved']
      assert result['protection_waiting_quote']
      refute result.key?('waiting_quote')
      assert_equal R::Amount.parse('120'),position.reload.take_profit_units
      assert_equal R::Amount.parse('90'),position.stop_loss_units
      R::Exchange.process(item.id)
      assert R::Position.exists?(position.id)
      assert_equal before,[R::Order.count,R::Journal.count,R::Account.wallet(@alice.id).balance]
      protect(position,tp:nil,sl:nil)
      assert_nil position.reload.take_profit_units
      assert_nil position.stop_loss_units
    end
  ensure
    R::MarketData.define_singleton_method(:refresh_if_needed,network) if network
  end

  def test_saved_stop_only_executes_when_valid_price_returns_and_replay_is_safe
    fund; item=instrument; fill(item, order(item)); position=R::Position.first!
    item.update!(quote: {})
    result=protect(position,request_id:'save-stale')
    replay=protect(position,request_id:'save-stale')
    assert_equal result.except('replayed'),replay.except('replayed')
    assert replay['replayed']
    R::Exchange.process(item.id)
    assert R::Position.exists?(position.id)
    item.update!(quote:quote('89'))
    R::Exchange.process(item.id)
    refute R::Position.exists?(position.id)
    assert_equal 2,R::Order.count
    assert_equal 0,R::Entry.sum(:units)
  end

  def test_missing_quote_keeps_price_order_profit_liquidation_and_ownership_checks
    fund; item=instrument; fill(item, order(item)); position=R::Position.first!
    item.update!(quote:{})
    assert_code('take_profit_not_profitable') { protect(position,tp:'99',sl:nil) }
    assert_code('stop_loss_beyond_liquidation') { protect(position,tp:nil,sl:'70') }
    assert_code('invalid_protection') { protect(position,tp:'120',sl:'130') }
    assert_raises(ActiveRecord::RecordNotFound) do
      R::Exchange.protect(actor:@bob,position_id:position.id,take_profit:'120',stop_loss:nil,request_id:SecureRandom.uuid)
    end
    R::Account.wallet(@alice.id).update!(status:'frozen')
    assert_code('wallet_frozen') { protect(position) }
  end

  def test_short_position_can_be_protected_during_closed_session
    fund; item=instrument
    R::Exchange.submit(actor:@alice,instrument_id:item.id,side:'short',quantity:'1',leverage:5,request_id:SecureRandom.uuid)
    position=R::Position.first!
    item.update!(quote:quote('100').merge('received_at'=>1.day.ago.iso8601,'session_end'=>1.hour.ago.iso8601))
    protect(position,tp:'80',sl:'110')
    assert_equal R::Amount.parse('80'),position.reload.take_profit_units
    assert_equal R::Amount.parse('110'),position.stop_loss_units
    assert_code('invalid_protection') { protect(position,tp:'80',sl:'70') }
    assert_code('take_profit_not_profitable') { protect(position,tp:'101',sl:nil) }
  end
end
