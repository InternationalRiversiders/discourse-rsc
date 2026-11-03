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
        assert_equal 0,report[:cold_used]
        assert_equal ['close_order'],report[:rows].map{|r|r[:operation]}.uniq
        assert_equal ['requests','success'],report[:rows].map{|r|r[:outcome]}.sort
        assert_nil Thread.current[:rsc_fallback_purpose]
      end
    end
  end

  def test_cold_budget_cannot_block_explicit_trading_or_exposed_refreshes
    item=fx;key="rsc:fx-fallback:cold:#{Time.current.utc.to_date}"
    Discourse.redis.set(key,B::COLD_LIMIT)
    B.with_context(:read) do
      error=assert_raises(R::Error){B.request(item,reason:'quote_verification'){flunk 'No HTTP after cold limit'}}
      assert_equal 'provider_background_budget',error.code
    end
    B.with_context(:exit){assert_equal :ok,B.request(item,reason:'stale_execution'){:ok}}
    Discourse.redis.del('rsc:fx-fallback:slot')
    R::Position.create!(user_id:@alice.id,instrument_id:item.id,side:'long',leverage:1,
      quantity_units:R::Amount.parse('1'),average_units:R::Amount.parse('1'),margin_units:R::Amount.parse('1'))
    B.with_context(:forex_fast){assert_equal :ok,B.request(item,reason:'backup_continuity'){:ok}}
    Discourse.redis.del('rsc:fx-fallback:slot')
    R::Position.delete_all
    R::ForexReviewQueue.watch(item.id,trading:true)
    B.with_context(:forex_review){assert_equal :ok,B.request(item,reason:'quote_verification'){:ok}}
    assert_equal 3,B.report[:total_reserved]
    assert_equal B::COLD_LIMIT,B.report[:cold_used]
    assert_equal 'holding_refresh',B.report[:rows].find{|r|r[:operation]=='holding_refresh'}[:operation]
  end

  def test_shared_slot_and_total_limit_still_apply_to_priority_orders
    item=fx
    B.with_context(:trade){B.request(item,reason:'stale_execution'){:ok}}
    error=assert_raises(R::Error){B.with_context(:exit){B.request(item,reason:'stale_execution'){flunk 'Shared slot bypassed'}}}
    assert_equal 'provider_busy',error.code
    Discourse.redis.del('rsc:fx-fallback:slot')
    Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",750)
    error=assert_raises(R::Error){B.request(item,reason:'stale_execution'){flunk 'Daily cap bypassed'}}
    assert_equal 'provider_daily_limit',error.code
  end

  def test_provider_pacing_refunds_unspent_credit_but_network_errors_remain_counted
    item=fx
    %w[provider_busy provider_cooldown].each do |code|
      B.with_context(:read) do
        assert_raises(R::Error){B.request(item,reason:'quote_verification'){raise R::Error.new(code)}}
      end
      assert_equal 0,B.report[:total_reserved]
      assert_equal 0,B.report[:cold_used]
      Discourse.redis.del('rsc:fx-fallback:slot')
    end
    assert_raises(R::Error){B.request(item,reason:'stale_execution'){raise R::Error.new('provider_unavailable')}}
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
        R::MarketData.execution_quote(item,primary)
        assert_in_delta delay,Discourse.redis.ttl('rsc:fx-fallback:retry:CNY'),1
        Discourse.redis.del('rsc:fx-fallback:slot','rsc:fx-fallback:retry:CNY')
      end
      assert_equal 4,calls.size
      data['timestamp']=Time.current.to_i
      assert_equal 'twelve_data',R::MarketData.execution_quote(item,primary)['source']
      assert_nil Discourse.redis.get('rsc:fx-fallback:failures:CNY')
      assert_equal 5,B.report[:total_reserved]
    end
  end
  def test_background_ceiling_preserves_credits_for_explicit_orders
    item=fx;Discourse.redis.set("rsc:fx-fallback:requests:#{Time.current.utc.to_date}",600)
    error=assert_raises(R::Error){B.with_context(:forex_fast){B.request(item,reason:'backup_continuity'){flunk 'Background spent reserve'}}}
    assert_equal 'provider_background_budget',error.code
    B.with_context(:exit){assert_equal :ok,B.request(item,reason:'stale_execution'){:ok}}
    assert_equal 601,B.report[:total_reserved]
  end

  def test_holding_continuity_is_paced_but_execution_and_verification_are_not
    item=fx
    B.with_context(:forex_fast){B.request(item,reason:'backup_continuity'){:ok}}
    Discourse.redis.del('rsc:fx-fallback:slot')
    error=assert_raises(R::Error){B.with_context(:forex_fast){B.request(item,reason:'backup_continuity'){flunk 'Repeated holding fetch'}}}
    assert_equal 'provider_background_paced',error.code
    assert_equal 1,B.report[:total_reserved]
    B.with_context(:exit){B.request(item,reason:'stale_execution'){:ok}}
    Discourse.redis.del('rsc:fx-fallback:slot')
    B.with_context(:forex_fast){B.request(item,reason:'quote_verification'){:ok}}
    assert_equal 3,B.report[:total_reserved]
  end

  def test_valid_backup_reused_past_one_minute_but_review_gets_independent_samples
    travel_to(Time.utc(2026,11,3,12)) do
      item=fx;data={'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>Time.current.to_i}
      feeds(quote('0.15'),data) do |calls|
        first=R::MarketData.forex_fallback(item)
        travel 90.seconds
        assert_equal first,R::MarketData.forex_fallback(item)
        assert_equal 1,calls.size
        item.update!(quote:item.quote.merge('verification'=>{'status'=>'pending'}))
        data['timestamp']=Time.current.to_i
        Discourse.redis.del('rsc:fx-fallback:slot')
        second=R::MarketData.forex_fallback(item)
        assert_equal 2,calls.size
        assert_operator Time.iso8601(second['source_time']),:>,Time.iso8601(first['source_time'])
      end
    end
  end

  def test_cached_backup_expires_by_source_clock_even_before_cache_ttl
    travel_to(Time.utc(2026,11,3,12)) do
      item=fx;data={'symbol'=>'USD/CNY','rate'=>'6.67','timestamp'=>150.seconds.ago.to_i}
      feeds(quote('0.15'),data) do |calls|
        R::MarketData.forex_fallback(item)
        travel 31.seconds;data['timestamp']=Time.current.to_i
        Discourse.redis.del('rsc:fx-fallback:slot')
        result=R::MarketData.forex_fallback(item)
        assert_equal 2,calls.size;assert R::ForexQuoteGuard.fresh?(result)
      end
    end
  end

end
