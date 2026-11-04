# frozen_string_literal: true
require '/rsc/test/fallback_priority_test'

class RiskRefreshTest < FallbackPriorityTest
  FallbackPriorityTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  T = R::QuoteTelemetry

  def telemetry(stage)
    T.report[:rows].select { |r| r[:stage] == stage }.group_by { |r| r[:outcome] }
      .transform_values { |rows| rows.sum { |r| r[:count] } }
  end

  def test_distant_stop_settings_do_not_raise_background_priority
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=exposed_position
      R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:'1.021',stop_loss:nil,request_id:SecureRandom.uuid)
      assert_equal :routine,R::ExecutionDemand.priority(item,purpose: :execution)
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",500)
      blocked('provider_background_budget'){reserve(item)}
      # A submit/exit is independent of the downgraded background poll.
      assert_equal :ok,reserve(item,purpose: :trade)
      release_slot
      assert_equal :ok,reserve(item,purpose: :exit)
      position.update!(take_profit_units:R::Amount.parse('1.001'))
      assert_equal :protection,R::ExecutionDemand.priority(item,purpose: :execution)
    end
  end

  def test_watchdog_uses_leverage_and_real_quote_age_not_new_candidate_or_poll_time
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=exposed_position
      assert_equal :routine,R::ExecutionDemand.priority(item,purpose: :execution)
      travel 60.seconds
      assert_equal :protection,R::ExecutionDemand.priority(item,purpose: :execution)
      item.update!(synced_at:Time.current,quote:item.quote.merge('verification'=>{'status'=>'pending','candidate'=>observation('1')}))
      travel 6.minutes
      assert_equal :urgent,R::ExecutionDemand.priority(item,purpose: :execution)
      # Low leverage still has a bounded periodic check even with no stops.
      position.update!(leverage:1)
      assert_equal :routine,R::ExecutionDemand.priority(item,purpose: :execution)
      travel 3.minutes
      assert_equal :protection,R::ExecutionDemand.priority(item,purpose: :execution)
      travel 15.minutes
      assert_equal :urgent,R::ExecutionDemand.priority(item,purpose: :execution)
      # Neither a recently received old quote nor a malformed clock hides age.
      item.update!(quote:item.quote.merge('received_at'=>Time.current.iso8601))
      assert_equal :urgent,R::ExecutionDemand.priority(item,purpose: :execution)
      item.update!(quote:item.quote.merge('source_time'=>'invalid'))
      assert_equal :urgent,R::ExecutionDemand.priority(item,purpose: :execution)
    end
  end

  def test_stale_watchdog_can_use_risk_reserve_and_fresh_result_resets_it
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,stale=exposed_position
      travel 7.minutes
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",650)
      with_backup_feed(stale,'1.0001') do |calls|
        poll
        assert_equal ['USD/BRL'],calls
        assert_equal :routine,R::ExecutionDemand.priority(item.reload,purpose: :execution)
        assert R::Position.exists?(position.id)
        assert_equal 0,R::Order.where(side:'close').count
        assert_equal 651,B.report[:total_reserved]
      end
    end
  end

  def test_unknown_risk_fetch_does_not_fill_at_stale_price_on_provider_failure
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,stale=exposed_position
      travel 7.minutes
      with_backup_feed(stale,R::Error.new('provider_unavailable')) do |calls|
        before=R::Account.wallet(@alice.id).balance
        poll;poll
        assert_equal ['USD/BRL'],calls
        assert R::Position.exists?(position.id)
        assert_equal before,R::Account.wallet(@alice.id).balance
        assert_equal 0,R::Order.where(side:'close').count
      end
    end
  end

  def test_network_repeat_revision_regression_and_cache_are_separate
    travel_to(Time.utc(2026,11,4,12)) do
      item=live_fx(observation('1'))
      q=observation('1',source:'twelve_data')
      T.response(item,q)
      T.response(item,q.merge('price'=>'1.0')) # numeric equality
      T.response(item,q.merge('price'=>'1.001'))
      T.response(item,q.merge('source_time'=>1.minute.ago.iso8601))
      T.response(item,q.merge('source_time'=>1.second.from_now.iso8601))
      T.response(item,q.merge('source_time'=>10.minutes.ago.iso8601))
      T.count(item,q,'cache','hit')
      assert_equal({'first'=>1,'duplicate'=>1,'revision'=>1,'regression'=>2,'new_timestamp'=>1},telemetry('response'))
      assert_equal({'fresh'=>5,'stale'=>1},telemetry('freshness'))
      assert_equal({'hit'=>1},telemetry('cache'))
      assert_equal 0,B.report[:total_reserved]
      assert B.report[:quote_telemetry][:tracked_since]
    end
  end

  def test_real_fetch_and_cached_replay_have_one_network_observation
    travel_to(Time.utc(2026,11,4,12)) do
      item,_,stale=exposed_position
      with_backup_feed(stale,'1.0001') do |calls|
        B.with_context(:trade) do
          first=R::MarketData.forex_fallback(item)
          second=R::MarketData.forex_fallback(item)
          assert_equal first,second
        end
        assert_equal ['USD/BRL'],calls
        assert_equal({'first'=>1},telemetry('response'))
        assert_equal({'hit'=>1},telemetry('cache'))
        assert_equal 1,B.report[:total_reserved]
      end
    end
  end

  def test_review_adoption_repeats_and_stale_rejection_are_counted
    travel_to(Time.utc(2026,11,4,12)) do
      item=live_fx(observation('1'))
      accept(item,'1.002')
      assert G.pending?(item.reload.quote)
      3.times do |n|
        q=observation('1.001',source:'twelve_data')
        R::MarketData.record_quote(item,q)
        travel 60.seconds if n<2
      end
      refute G.pending?(item.reload.quote)
      R::MarketData.record_quote(item,item.quote)
      R::MarketData.record_quote(item,observation('1',at:1.hour.ago))
      assert_equal 3,telemetry('decision')['pending_review']
      assert_equal 1,telemetry('decision')['adopted']
      assert_equal 1,telemetry('decision')['accepted_repeat']
      assert_equal 1,telemetry('decision')['rejected_stale']
      assert_equal({'backup_consensus'=>1},telemetry('review_completed'))
      assert_empty telemetry('response') # record/cache paths must not invent HTTP
    end
  end

  def test_telemetry_failure_does_not_block_quote_adoption
    travel_to(Time.utc(2026,11,4,12)) do
      item=live_fx(observation('1'))
      original=T.method(:prefix)
      T.define_singleton_method(:prefix){|*_|raise IOError,'telemetry-only failure'}
      begin
        R::MarketData.record_quote(item,observation('1.0001'))
        assert_equal '1.0001',item.reload.quote['price']
      ensure
        T.define_singleton_method(:prefix,original)
      end
    end
  end
  def test_rolled_back_quote_is_not_reported_as_adopted
    travel_to(Time.utc(2026,11,4,12)) do
      item=live_fx(observation('1'))
      R::Instrument.transaction do
        R::MarketData.record_quote(item,observation('1.0001'))
        raise ActiveRecord::Rollback
      end
      assert_equal '1',item.reload.quote['price']
      assert_empty telemetry('decision')
    end
  end

  [[nil,nil,'0.992','stock_liquidated'],
   ['1.021',nil,'1.022','stock_take_profit'],
   [nil,'0.994','0.993','stock_stop_loss']].each do |tp,sl,price,reason|
    define_method("test_stale_watchdog_discovers_#{reason}_despite_old_safe_mark") do
      travel_to(Time.utc(2026,11,4,12)) do
        item,position,stale=exposed_position
        if tp || sl
          R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:tp,stop_loss:sl,request_id:SecureRandom.uuid)
        end
        assert_equal :routine,R::ExecutionDemand.priority(item,purpose: :execution)
        travel 7.minutes
        Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",650)
        with_backup_feed(stale,price) do |calls|
          review_samples(item) do |n|
            poll
            assert R::Position.exists?(position.id) if n<2
          end
          assert_equal 3,calls.size
          refute R::Position.exists?(position.id)
          assert_equal reason,R::Order.where(side:'close').sole.details['reason']
          assert_equal 653,B.report[:total_reserved]
          assert_equal 0,R::Entry.sum(:units)
        end
      end
    end
  end

end
