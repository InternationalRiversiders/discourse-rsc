# frozen_string_literal: true
require '/rsc/test/fallback_priority_test'

class RiskRefreshTest < FallbackPriorityTest
  FallbackPriorityTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  T = R::QuoteTelemetry

  def telemetry(stage)
    T.report[:rows].select { |r| r[:stage] == stage }.group_by { |r| r[:outcome] }
      .transform_values { |rows| rows.sum { |r| r[:count] } }
  end

  def test_old_and_near_risk_prices_do_not_grant_background_backup
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,_=exposed_position
      travel 1.hour
      position.update!(stop_loss_units:R::Amount.parse('1.001'))
      %i[execution forex_review].each do |purpose|
        blocked('provider_execution_only'){reserve(item,purpose:purpose)}
      end
      assert_equal :ok,reserve(item,purpose: :trade)
      release_slot
      assert_equal :ok,reserve(item,purpose: :exit)
      assert_equal 2,B.report[:total_reserved]
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

end
