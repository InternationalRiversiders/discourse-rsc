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

  def test_opening_reserve_survives_background_protection_and_preserves_exits
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,_=protected_position(tp:'1.001',sl:'0.999')
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",600)
      blocked('provider_execution_only'){reserve(item)}
      assert_equal :ok,reserve(item,purpose: :trade)
      release_slot
      Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",650)
      blocked('provider_background_budget'){reserve(item,purpose: :trade)}
      assert_equal :ok,reserve(item,purpose: :exit)
    end
  end

  def test_holding_risk_never_authorizes_background_credit
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=exposed_position
      [nil,'1.001','0.999'].each do |sl|
        position.update!(stop_loss_units:sl && R::Amount.parse(sl))
        [0,450,749].each do |used|
          Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",used)
          %i[execution forex_review].each do |purpose|
            blocked('provider_execution_only'){reserve(item,purpose:purpose)}
          end
          assert_equal used,B.report[:total_reserved]
        end
      end
    end
  end

  def test_unsent_manual_request_refunds_credit
    travel_to(Time.utc(2026,11,4,12)) do
      item,_,_=exposed_position
      blocked('provider_busy'){reserve(item,purpose: :exit){raise R::Error.new('provider_busy')}}
      assert_equal 0,B.report[:total_reserved]
      release_slot
      assert_equal :ok,reserve(item,purpose: :exit)
      assert_equal({'exit'=>1},B.report[:requests_by_priority])
    end
  end
end
