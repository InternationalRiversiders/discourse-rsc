# frozen_string_literal: true
require '/rsc/test/forex_primary_policy_test'
class ForexReviewQueueTest < ForexPrimaryPolicyTest
  ForexPrimaryPolicyTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  Q = R::ForexReviewQueue

  def quarantined(code)
    item=forex("FX:#{code}")
    item.update!(provider:'yahoo',provider_symbol:"#{code}=X",quote:observation('1'))
    accept(item,'1.002')
    assert G.pending?(item.quote)
    item
  end

  def test_turn_is_shared_bounded_and_rotates_after_timeout_or_failure
    Q.enqueue(11);Q.enqueue(12)
    assert_equal 11,Q.claim
    refute Q.turn?(12)
    assert_operator Discourse.redis.ttl(Q::ACTIVE),:<=,Q::TURN_SECONDS
    # Simulate lease expiry without sleeping or changing Redis's clock.
    Discourse.redis.del(Q::ACTIVE)
    assert_equal 12,Q.claim
    Q.finish(11)
    assert_equal '12',Discourse.redis.get(Q::ACTIVE)
    Q.finish(12,retry_in:300)
    Q.enqueue(12) # read requests must not erase the backoff
    assert_equal 0,Q.claim
    Q.finish(12)
    assert_equal 0,Discourse.redis.zcard(Q::QUEUE)
  end

  def test_due_order_quarantine_gets_independent_backup_samples_and_releases_turn
    travel_to(Time.utc(2026,11,3,12)) do
      SiteSetting.rsc_market_data_enabled=true
      SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
      fund
      first=quarantined('BRL');second=quarantined('NOK')
      R::Order.create!(user_id:@alice.id,instrument_id:first.id,side:'long',leverage:1,
        quantity_units:R::Amount.parse('1'),reserved_units:0,status:'pending',
        execute_at:1.second.ago,expires_at:10.minutes.from_now,details:{})
      # Recovery seeds pre-release rows even if the transient queue is absent.
      Discourse.redis.del(Q::QUEUE,Q::ACTIVE)
      3.times do |n|
        Discourse.redis.del("rsc:fx-review:#{first.id}")
        yielded=[]
        with_feeds(observation('1.002'),observation('1.001',source:'twelve_data')) do |calls|
          assert_equal [first.id],R::MarketData.sync_forex { |id| yielded << id }
          assert_equal({primary:1,backup:1},calls)
        end
        assert_equal [first.id],yielded
        assert_equal '1',first.reload.quote['price'] if n<2
        assert G.pending?(second.reload.quote)
        travel 60.seconds if n<2
      end
      refute G.pending?(first.reload.quote)
      assert_equal 'backup_consensus',first.quote.dig('verification','method')
      assert_equal '1.001',first.quote['price']
      assert_equal 0,Q.claim
      assert_equal 1,R::Order.where(status: 'pending').count
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_competing_requests_do_not_spend_backup_credit_and_busy_retries_soon
    travel_to(Time.utc(2026,11,3,12)) do
      SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
      first=quarantined('BRL');second=quarantined('NOK')
      assert Q.turn?(first.id)
      with_feeds(observation('1.002'),R::Error.new('provider_busy')) do |calls|
        R::FallbackBudget.with_context(:trade) { R::MarketData.verify_forex_quote(second) }
        assert_equal({primary:0,backup:0},calls)
        R::FallbackBudget.with_context(:trade) { R::MarketData.verify_forex_quote(first) }
        assert_equal({primary:1,backup:1},calls)
        assert_operator Discourse.redis.ttl("rsc:fx-review:#{first.id}"),:<=,10
        assert_equal first.id,Q.claim
        assert G.pending?(first.reload.quote)
      end
    end
  end

  def test_daily_limit_defers_review_until_reset_without_resetting_guard
    travel_to(Time.utc(2026,11,3,12)) do
      SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
      item=quarantined('BRL')
      with_feeds(observation('1.002'),R::Error.new('provider_daily_limit')) do |calls|
        R::FallbackBudget.with_context(:trade) { R::MarketData.verify_forex_quote(item) }
        assert_equal({primary:1,backup:1},calls)
        assert G.pending?(item.reload.quote)
        assert_equal 'provider_daily_limit',item.quote.dig('verification','backup_error')
        assert_nil Q.next_instrument
        R::FallbackBudget.with_context(:trade) { R::MarketData.verify_forex_quote(item) }
        assert_equal 1,calls[:backup]
      end
    end
  end

  def test_inactive_or_resolved_rows_leave_queue_and_closed_markets_back_off
    travel_to(Time.utc(2026,11,3,12)) do
      item=quarantined('BRL');item.update!(active:false)
      assert_nil Q.next_instrument
      assert_equal 0,Q.claim
      item.update!(active:true,quote:observation('1'))
      Q.enqueue(item.id)
      assert_nil Q.next_instrument
      assert_equal 0,Q.claim
      accept(item,'1.002')
      travel_to(Time.utc(2026,11,7,12))
      assert_nil Q.next_instrument
      assert_equal 0,Q.claim
    end
  end
  def test_unwatched_unheld_symbols_do_not_spend_credits_or_hold_review_turn
    travel_to(Time.utc(2026,11,3,12)) do
      SiteSetting.rsc_market_data_enabled=true
      SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
      first=quarantined('BRL')
      Discourse.redis.del("rsc:fx-review-watch:#{first.id}")
      with_feeds(observation('1.002'),R::Error.new('provider_daily_limit')) do |calls|
        assert_empty R::MarketData.sync_forex
        R::MarketData.refresh_if_needed(first.id,purpose: :idle)
        assert_equal 0,calls[:backup]
        assert G.pending?(first.reload.quote)
        assert_equal 0,Q.claim
        R::MarketData.refresh_if_needed(first.id,purpose: :read)
        assert_equal 0,calls[:backup]
        refute Q.eligible?(first.id)
      end
    end
  end

  def test_legacy_background_deferral_does_not_block_later_trade_review
    travel_to(Time.utc(2026,11,3,12)) do
      SiteSetting.rsc_market_data_enabled=true
      SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
      item=quarantined('BRL')
      item.update!(quote:item.quote.merge('verification'=>item.quote['verification'].merge('backup_error'=>'provider_background_budget')))
      Q.finish(item.id,retry_in:3600)
      with_feeds(observation('1.002'),observation('1.001',source:'twelve_data')) do |calls|
        R::MarketData.refresh_if_needed(item.id,purpose: :trade)
        assert_equal 1,calls[:backup]
        assert G.pending?(item.reload.quote) # One sample must not bypass guard.
      end
    end
  end

end
