# frozen_string_literal: true
require '/rsc/test/execution_lifecycle_test'

class PrimaryAutomaticTest < ExecutionLifecycleTest
  ExecutionLifecycleTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def test_cached_backup_cannot_trigger_stop_even_if_another_user_requested_it
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=protected_position
      accept(item,'1.0001') # Both feeds are fresh; only the backup crosses TP.
      R::MarketData.record_quote(item,observation('1.0004',source:'twelve_data'))
      assert_equal 'twelve_data',item.reload.quote['source']
      before=R::Account.wallet(@alice.id).balance
      R::Exchange.process(item.id)
      assert R::Position.exists?(position.id)
      assert_equal before,R::Account.wallet(@alice.id).balance
      assert_equal 0,R::Order.where(side:'close').count
      # A subsequent valid primary independently confirms the trigger.
      R::MarketData.record_quote(item,observation('1.0004'))
      R::Exchange.process(item.id)
      refute R::Position.exists?(position.id)
      assert_equal 'yahoo',R::Order.where(side:'close').sole.details.dig('execution_quote','source')
    end
  end

  def test_primary_protection_can_fill_while_manual_quote_still_waits_for_cross_source_review
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=exposed_position
      with_backup_feed(-> { observation('0.992') },R::Error.new('provider_daily_limit')) do |calls|
        review_samples(item) { poll }
        assert_empty calls
      end
      assert G.pending?(item.reload.quote) # Manual feed still uses stricter cross-source review.
      refute G.pending?(G.automatic_quote(item.quote))
      assert_equal 'primary_consensus',G.automatic_quote(item.quote).dig('verification','method')
      assert R::QuoteTelemetry.report[:rows].any? { |row| row[:stage] == 'automatic_review_completed' && row[:outcome] == 'primary_consensus' }
      refute R::Position.exists?(position.id)
      assert_equal '0.992',R::Order.where(side:'close').sole.details['price']
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_repeated_cached_spike_and_stale_primary_never_trigger
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=exposed_position
      q=observation('0.992')
      6.times do
        R::MarketData.record_quote(item,q)
        R::Exchange.process(item.id)
        travel 30.seconds
      end
      assert G.pending?(G.automatic_quote(item.reload.quote))
      assert R::Position.exists?(position.id)
      assert_equal 0,R::Order.where(side:'close').count
      # Retraction restores the original safe level without any fallback call.
      accept(item,'1')
      refute G.pending?(G.automatic_quote(item.quote))
      assert R::Position.exists?(position.id)
    end
  end

  def test_missing_primary_and_weekend_cannot_use_backup_for_automatic_execution
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=protected_position
      item.update!(quote:G.accepted(observation('0.9996',source:'twelve_data'),'initial'))
      R::Exchange.process(item.id)
      assert R::Position.exists?(position.id)
      travel_to(Time.utc(2026,11,7,12))
      item.update!(quote:observation('0.9996'))
      R::Exchange.process(item.id)
      assert R::Position.exists?(position.id)
      assert_equal 0,R::Order.where(side:'close').count
    end
  end

  def test_queued_manual_close_can_still_use_backup_without_autonomous_stop_using_it
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,stale=protected_position
      SiteSetting.rsc_market_data_enabled=false
      closing=submit(item,side:'close',quantity:'100',leverage:1)
      assert_equal 'pending',closing.status
      SiteSetting.rsc_market_data_enabled=true
      with_backup_feed(stale,'0.9996') do |calls|
        poll
        assert_equal ['USD/BRL'],calls
      end
      assert_equal 'filled',closing.reload.status
      assert_equal 'stock_closed',closing.details['reason']
      assert_equal 'twelve_data',closing.details.dig('execution_quote','source')
      refute closing.details['automatic']
      refute R::Position.exists?(position.id)
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_primary_quote_and_guard_survive_backup_updates_and_transaction_rollback
    travel_to(Time.utc(2026,11,4,12)) do
      item,_,_=protected_position
      accept(item,'1.0001')
      primary=G.automatic_quote(item.reload.quote)
      R::MarketData.record_quote(item,observation('1.0002',source:'twelve_data'))
      assert_equal primary,G.automatic_quote(item.reload.quote)
      R::Instrument.transaction do
        accept(item,'1.0003')
        raise ActiveRecord::Rollback
      end
      assert_equal primary,G.automatic_quote(item.reload.quote)
    end
  end
  def test_automatic_fill_and_audit_do_not_inherit_backup_bid_or_ask
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=protected_position
      accept(item,'1.0004')
      primary=G.automatic_quote(item.quote)
      item.update!(quote:G.accepted(observation('0.9',source:'twelve_data'),'backup_consensus')
        .merge('bid'=>'0.8','ask'=>'1.2','automatic_quote'=>primary))
      R::Exchange.process(item.id)
      closing=R::Order.where(side:'close').sole
      assert_equal '1.0004',closing.details['price']
      assert_equal 'stock_take_profit',closing.details['reason']
      assert_equal primary['source_time'],closing.details.dig('execution_quote','source_time')
      assert_equal 'yahoo',closing.details.dig('execution_quote','source')
      refute R::Position.exists?(position.id)
      assert_equal 0,R::Entry.sum(:units)
    end
  end

end
