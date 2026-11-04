# frozen_string_literal: true
require '/rsc/test/execution_lifecycle_test'

class FallbackPriorityTest < ExecutionLifecycleTest
  ExecutionLifecycleTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def reserve(item, purpose: :execution, reason: 'stale_execution', &block)
    B.with_context(purpose) { B.request(item, reason: reason, &(block || -> { :ok })) }
  end

  def release_slot
    Discourse.redis.del('rsc:fx-fallback:slot')
  end

  def blocked(code)
    assert_equal code, assert_raises(R::Error) { yield }.code
  end

  def test_routine_probes_share_daily_pool_and_ten_minute_interval
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,_=exposed_position(leverage:1)
      assert_equal :ok,reserve(item)
      release_slot
      travel 4.minutes
      blocked('provider_background_paced'){reserve(item){flunk 'Routine probe too soon'}}
      travel 6.minutes
      assert_equal :ok,reserve(item)
      assert_equal 2,B.report[:routine_used]
      assert_equal({'routine'=>2},B.report[:requests_by_priority])
      release_slot
      travel 10.minutes
      Discourse.redis.set("rsc:fallback-routine:#{Time.current.utc.to_date}",150)
      blocked('provider_background_budget'){reserve(item){flunk 'Routine pool exhausted'}}
      assert_equal :ok,reserve(item,purpose: :exit)
    end
  end

  def test_ordinary_checks_and_opening_cannot_spend_the_exit_reserve
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,_=exposed_position(leverage:1)
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",450)
      blocked('provider_background_budget'){reserve(item)}
      assert_equal :ok,reserve(item,purpose: :trade)
      release_slot
      assert_equal :ok,reserve(item,purpose: :exit)
      release_slot
      position=R::Position.find_by!(instrument_id:item.id)
      position.update!(stop_loss_units:R::Amount.parse('0.999'))
      assert_equal :ok,reserve(item)
      assert_equal 453,B.report[:total_reserved]
      assert_equal({'opening'=>1,'exit'=>1,'protection'=>1},B.report[:requests_by_priority])
    end
  end

  def test_non_imminent_stops_are_paced_but_trigger_and_manual_exit_bypass
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,_=protected_position(tp:'1.1',sl:'0.9')
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",550)
      assert_equal :ok,reserve(item)
      release_slot;travel 1.minute
      blocked('provider_background_paced'){reserve(item)}
      assert_equal :ok,reserve(item,purpose: :exit)
      release_slot
      position.update!(stop_loss_units:R::Amount.parse('1.001'))
      assert_equal :ok,reserve(item)
      release_slot
      position.update!(stop_loss_units:R::Amount.parse('0.9'))
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",650)
      blocked('provider_background_budget'){reserve(item)}
      position.update!(take_profit_units:R::Amount.parse('1.001'))
      item.update!(quote:item.quote.merge('price'=>'1.002'))
      assert_equal :ok,reserve(item)
    end
  end

  def test_liquidation_proximity_and_quarantined_candidate_escalate_without_filling
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,_=exposed_position
      assert_equal :routine,R::ExecutionDemand.priority(item,purpose: :execution)
      item.update!(quote:item.quote.merge('price'=>'0.994'))
      assert_equal :protection,R::ExecutionDemand.priority(item,purpose: :execution)
      accept(item,'0.992')
      assert G.pending?(item.reload.quote)
      assert_equal :urgent,R::ExecutionDemand.priority(item,purpose: :execution)
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",749)
      assert_equal :ok,reserve(item)
      R::Exchange.process(item.id)
      assert R::Position.exists?(position.id)
      assert_equal 0,R::Order.where(side:'close').count
      assert_equal 750,B.report[:total_reserved]
      blocked('provider_daily_limit'){reserve(item,purpose: :exit)}
    end
  end

  def test_bounded_routine_review_burst_can_finish_three_independent_samples
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,_=exposed_position(leverage:1)
      assert_equal :ok,reserve(item)
      2.times do
        travel 60.seconds;release_slot
        assert_equal :ok,reserve(item,reason:'quote_verification')
      end
      travel 60.seconds;release_slot
      blocked('provider_background_paced'){reserve(item,reason:'quote_verification')}
      assert_equal 3,B.report[:routine_used]
    end
  end

  def test_distant_protection_review_can_complete_despite_daily_pacing
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,_=protected_position(tp:'1.1',sl:'0.9')
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",550)
      assert_equal :ok,reserve(item)
      2.times do
        travel 60.seconds;release_slot
        assert_equal :ok,reserve(item,reason:'quote_verification')
      end
      travel 60.seconds;release_slot
      blocked('provider_background_paced'){reserve(item,reason:'quote_verification')}
      assert_equal 553,B.report[:total_reserved]
      assert_equal 0,B.report[:routine_used]
    end
  end

  def test_not_sent_request_refunds_counters_and_restores_pacing
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,_=exposed_position(leverage:1)
      blocked('provider_busy'){reserve(item){raise R::Error.new('provider_busy')}}
      assert_equal 0,B.report[:routine_used]
      assert_equal 0,B.report[:total_reserved]
      release_slot
      assert_equal :ok,reserve(item)
      assert_equal 1,B.report[:routine_used]
      release_slot;travel 60.seconds
      blocked('provider_cooldown'){reserve(item,reason:'quote_verification'){raise R::Error.new('provider_cooldown')}}
      release_slot
      assert_equal :ok,reserve(item,reason:'quote_verification')
      assert_equal 2,B.report[:routine_used]
    end
  end

  def test_manual_exit_preempts_routine_review_and_pending_close_is_priority
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,_=exposed_position(leverage:1)
      accept(item,'1.002')
      assert R::ForexReviewQueue.turn?(item.id)
      other=forex('FX:NOK');other.update!(provider:'yahoo',provider_symbol:'NOK=X',quote:observation('1'))
      accept(other,'1.002')
      B.with_context(:exit){assert R::ForexReviewQueue.turn?(other.id)}
      assert_equal other.id,R::ForexReviewQueue.claim
      R::Order.create!(user_id:@alice.id,instrument_id:item.id,side:'close',leverage:1,
        quantity_units:R::Amount.parse('1'),status:'pending',execute_at:1.second.ago,expires_at:10.minutes.from_now)
      assert_equal :exit,R::ExecutionDemand.priority(item,purpose: :execution)
    end
  end

  def test_reserved_budget_still_funds_real_stop_loss_execution
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=protected_position
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",500)
      with_backup_feed(stale,'0.9996') do |calls|
        poll
        assert_equal ['USD/BRL'],calls
        refute R::Position.exists?(position.id)
        assert_equal 'stock_stop_loss',R::Order.where(side:'close').sole.details['reason']
        assert_equal 0,R::Entry.sum(:units)
      end
    end
  end

  def test_routine_pool_stop_does_not_block_a_real_manual_close
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=exposed_position(leverage:1)
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",700)
      with_backup_feed(stale,'0.9999') do |calls|
        poll
        assert_empty calls
        closing=submit(item,side:'close',quantity:'100',leverage:1)
        assert_equal 'filled',closing.status
        refute R::Position.exists?(position.id)
        assert_equal ['USD/BRL'],calls
        assert_equal({'exit'=>1},B.report[:requests_by_priority])
        assert_equal 0,R::Entry.sum(:units)
      end
    end
  end

  def test_routine_budget_resets_on_next_utc_day_and_viewing_still_cannot_fetch
    travel_to(Time.utc(2026,11,3,23,59)) do
      item,_,_=exposed_position(leverage:1)
      Discourse.redis.set("rsc:fallback-routine:#{Time.current.utc.to_date}",150)
      blocked('provider_background_budget'){reserve(item)}
      travel 2.minutes
      assert_equal :ok,reserve(item)
      blocked('provider_execution_only'){reserve(item,purpose: :read)}
    end
  end
  def test_opening_reserve_survives_background_protection_and_preserves_exits
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,_=protected_position(tp:'1.1',sl:'0.9')
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",600)
      blocked('provider_background_budget'){reserve(item)}
      assert_equal :ok,reserve(item,purpose: :trade)
      release_slot
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",650)
      blocked('provider_background_budget'){reserve(item,purpose: :trade)}
      assert_equal :ok,reserve(item,purpose: :exit)
    end
  end

end
