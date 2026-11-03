# frozen_string_literal: true
require '/rsc/test/forex_fallback_test'
class FallbackBudgetTest < ForexFallbackTest
  ForexFallbackTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  B=R::FallbackBudget

  def test_cache_reuse_attributes_only_the_actual_fetch_to_its_operation
    travel_to(Time.utc(2026,11,3,12)) do
      item=fx;primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601)
      feeds(primary,{'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>Time.current.to_i}) do |calls|
        B.with_context(:exit) { R::MarketData.execution_quote(item,primary) }
        B.with_context(:trade) { R::MarketData.execution_quote(item,primary) }
        assert_equal 1,calls.size
        report=B.report
        assert_equal 1,report[:total_reserved]
        assert_equal ['close_order'],report[:rows].map{|r|r[:operation]}.uniq
        assert_equal ['requests','success'],report[:rows].map{|r|r[:outcome]}.sort
        assert_nil Thread.current[:rsc_fallback_purpose]
      end
    end
  end

  def test_non_trading_contexts_cannot_spend_even_with_holdings_or_recent_submission
    item=fx
    R::Position.create!(user_id:@alice.id,instrument_id:item.id,side:'long',leverage:1,
      quantity_units:R::Amount.parse('1'),average_units:R::Amount.parse('1'),margin_units:R::Amount.parse('1'))
    Discourse.redis.setex("rsc:fx-review-request:#{item.id}",600,'1')
    [nil,:read,:forex_fast,:background,:idle,:protection,:forex_review,:execution].each do |purpose|
      B.with_context(purpose) do
        error=assert_raises(R::Error){B.request(item,reason:'quote_verification'){flunk 'Non-trading HTTP'}}
        assert_equal 'provider_execution_only',error.code
      end
    end
    assert_equal 0,B.report[:total_reserved]
    assert_empty B.report[:rows]
    assert_nil Discourse.redis.get('rsc:fx-fallback:slot')
  end

  def test_only_due_live_orders_allow_background_execution_or_review
    fund;item=fx
    order=R::Order.create!(user_id:@alice.id,instrument_id:item.id,side:'long',leverage:1,
      quantity_units:R::Amount.parse('1'),reserved_units:0,status:'pending',
      execute_at:1.second.ago,expires_at:10.minutes.from_now,details:{})
    %i[execution forex_review].each do |purpose|
      B.with_context(purpose){assert_equal :ok,B.request(item,reason:'quote_verification'){:ok}}
      Discourse.redis.del('rsc:fx-fallback:slot')
    end
    [{execute_at:1.minute.from_now},{execute_at:1.second.ago,expires_at:1.second.ago},
      {expires_at:10.minutes.from_now,status:'canceled'}, {status:'filled'}].each do |changes|
      order.update!(changes)
      %i[execution forex_review].each do |purpose|
        B.with_context(purpose){refute B.allowed?(item)}
      end
    end
    assert_equal 2,B.report[:total_reserved]
  end

  def test_shared_slot_and_total_limit_still_apply_to_priority_orders
    item=fx
    B.with_context(:trade){B.request(item,reason:'stale_execution'){:ok}}
    error=assert_raises(R::Error){B.with_context(:exit){B.request(item,reason:'stale_execution'){flunk 'Shared slot bypassed'}}}
    assert_equal 'provider_busy',error.code
    Discourse.redis.del('rsc:fx-fallback:slot')
    Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",750)
    error=assert_raises(R::Error){B.with_context(:trade){B.request(item,reason:'stale_execution'){flunk 'Daily cap bypassed'}}}
    assert_equal 'provider_daily_limit',error.code
  end

  def test_provider_pacing_refunds_unspent_credit_but_network_errors_remain_counted
    item=fx
    %w[provider_busy provider_cooldown].each do |code|
      B.with_context(:trade) do
        assert_raises(R::Error){B.request(item,reason:'quote_verification'){raise R::Error.new(code)}}
      end
      assert_equal 0,B.report[:total_reserved]
      Discourse.redis.del('rsc:fx-fallback:slot')
    end
    assert_raises(R::Error){B.with_context(:trade){B.request(item,reason:'stale_execution'){raise R::Error.new('provider_unavailable')}}}
    assert_equal 1,B.report[:total_reserved]
    rows=B.report[:rows]
    assert_equal 1,rows.find{|r|r[:outcome]=='requests'}[:count]
    assert_equal 1,rows.find{|r|r[:outcome]=='failed:provider_unavailable'}[:count]
    assert_nil Thread.current[:rsc_fallback_purpose]
  end

  def test_repeated_bad_feed_backs_off_and_success_resets_failures
    item=fx;primary=quote('0.15').merge('source_time'=>10.minutes.ago.iso8601)
    data={'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>10.minutes.ago.to_i}
    feeds(primary,data) do |calls|
      [90,180,300,300].each do |delay|
        execution_quote(item,primary)
        assert_in_delta delay,Discourse.redis.ttl('rsc:fx-fallback:retry:CNY'),1
        Discourse.redis.del('rsc:fx-fallback:slot','rsc:fx-fallback:retry:CNY')
      end
      assert_equal 4,calls.size
      data['timestamp']=Time.current.to_i
      assert_equal 'twelve_data',execution_quote(item,primary)['source']
      assert_nil Discourse.redis.get('rsc:fx-fallback:failures:CNY')
      assert_equal 5,B.report[:total_reserved]
    end
  end
  def test_entire_remaining_daily_budget_is_available_to_orders
    item=fx;Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",749)
    B.with_context(:exit){assert_equal :ok,B.request(item,reason:'stale_execution'){:ok}}
    assert_equal 750,B.report[:total_reserved]
    assert_equal 'priority_exits',B.report[:policy]
  end

  def test_valid_backup_reused_past_one_minute_but_review_gets_independent_samples
    travel_to(Time.utc(2026,11,3,12)) do
      item=fx;data={'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>Time.current.to_i}
      feeds(quote('0.15'),data) do |calls|
        first=fallback_quote(item)
        travel 90.seconds
        assert_equal first,fallback_quote(item)
        assert_equal 1,calls.size
        item.update!(quote:item.quote.merge('verification'=>{'status'=>'pending'}))
        data['timestamp']=Time.current.to_i
        Discourse.redis.del('rsc:fx-fallback:slot')
        second=fallback_quote(item)
        assert_equal 2,calls.size
        assert_operator Time.iso8601(second['source_time']),:>,Time.iso8601(first['source_time'])
      end
    end
  end

  def test_cached_backup_expires_by_source_clock_even_before_cache_ttl
    travel_to(Time.utc(2026,11,3,12)) do
      item=fx;data={'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>150.seconds.ago.to_i}
      feeds(quote('0.15'),data) do |calls|
        fallback_quote(item)
        travel 31.seconds;data['timestamp']=Time.current.to_i
        Discourse.redis.del('rsc:fx-fallback:slot')
        result=fallback_quote(item)
        assert_equal 2,calls.size;assert R::ForexQuoteGuard.fresh?(result)
      end
    end
  end

end
