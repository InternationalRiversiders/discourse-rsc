# frozen_string_literal: true
require '/rsc/test/forex_activity_test'
class ForexQuoteGuardTest < ForexActivityTest
  ForexActivityTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  G = R::ForexQuoteGuard
  def setup
    super
    Discourse.redis.keys('rsc:fx-review:*').each { |key| Discourse.redis.del(key) }
  end
  def observation(price, source: 'yahoo', at: Time.current)
    quote(price).merge('source'=>source, 'source_time'=>at.iso8601(6), 'pricing_method'=>R::MarketData::FX_PRICING)
  end
  def accept(item, price, **options)
    R::MarketData.record_quote(item, observation(price, **options)); item.reload
  end
  def test_regular_prices_and_non_fx_are_unaffected
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex; item.update!(quote:observation('0.15'))
      travel 20.seconds; accept(item,'0.15001')
      refute G.pending?(item.quote)
      assert_equal '0.15001',item.quote['price']
      assert_equal R::Amount.parse('0.15001'),R::Exchange.price!(item,trading:true)
      stock=instrument;accept(stock,'500')
      assert_equal '500',stock.quote['price']
    end
  end
  def test_cny_spike_is_quarantined_then_retracted_without_history_pollution
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(quote:observation('0.14999925'))
      travel 30.seconds;accept(item,'0.15024490')
      assert G.pending?(item.quote)
      assert_equal '0.14999925',item.quote['price']
      assert_empty item.history
      assert_equal 'quote_verifying',assert_raises(R::Error){R::Exchange.price!(item)}.code
      refute R::MarketListing.tradable?(R::MarketListing.rows([item]).first)
      assert_nil R::MarketListing.execution_prices(item)
      assert_equal 'last_quote',R::Valuation.mark(item)[:basis]
      travel 10.seconds;accept(item,'0.15000000')
      refute G.pending?(item.quote)
      assert_equal ['0.15000000'],item.history.map{|h|h['price']}
    end
  end
  def test_duplicate_timestamp_does_not_confirm_and_stale_observation_is_rejected
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(quote:observation('0.15'))
      travel 10.seconds; at=Time.current
      5.times { accept(item,'0.1503',at:at);travel 15.seconds }
      assert G.pending?(item.quote)
      assert_equal 1,item.quote.dig('verification','observations','yahoo').size
      assert_nil G.apply(item.quote,observation('0.1503',at:5.minutes.ago))
    end
  end
  def test_primary_repetition_cannot_certify_an_unusual_price
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(quote:observation('0.15'))
      travel 10.seconds;accept(item,'0.1503');assert G.pending?(item.quote)
      travel 30.seconds;accept(item,'0.15031');assert G.pending?(item.quote)
      travel 30.seconds;accept(item,'0.15030');assert G.pending?(item.quote)
      assert_equal '0.15',item.quote['price']
    end
  end
  def test_sources_must_agree_and_fresh_conflict_blocks_sustained_candidate
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(quote:observation('0.150276508776148112'))
      3.times do
        travel 30.seconds;accept(item,'0.150010500735051453',source:'twelve_data')
        assert G.pending?(item.quote)
      end
      travel 1.second;accept(item,'0.150012',source:'yahoo')
      refute G.pending?(item.quote)
      assert_equal 'cross_source',item.quote.dig('verification','method')
    end
  end
  def test_alternating_source_clusters_never_confirm_each_other
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(quote:observation('0.1502765'))
      8.times do
        travel 30.seconds;accept(item,'0.15001',source:'twelve_data')
        assert G.pending?(item.quote)
        travel 1.second;accept(item,'0.1502765',source:'yahoo')
        assert G.pending?(item.quote)
      end
    end
  end
  def test_long_gap_and_small_source_switch_have_explicit_rules
    travel_to(Time.utc(2026,10,28,12)) do
      old=observation('0.15',at:10.minutes.ago)
      assert G.pending?(G.apply(old,observation('0.1503')))
      assert G.pending?(G.apply(old,observation('0.1503',source:'twelve_data')))
      assert_equal 'source_continuity',G.apply(old,observation('0.15001',source:'twelve_data')).dig('verification','method')
    end
  end
  def test_quarantine_prevents_liquidation_allows_exit_queue_and_records_execution
    travel_to(Time.utc(2026,10,28,12)) do
      fund;activity;item=forex;item.update!(quote:observation('1'))
      opening=submit(item);travel 1.second;accept(item,'1');R::Exchange.process(item.id)
      assert_equal 'filled',opening.reload.status
      assert_equal 'yahoo',opening.details.dig('execution_quote','source')
      travel 10.seconds;accept(item,'0.98')
      count=R::Order.count;R::Exchange.process(item.id)
      assert_equal count,R::Order.count
      assert_equal 1,R::Position.count
      close=submit(item,side:'close')
      assert close.details['waiting_quote'];assert_equal 'pending',close.status
      assert_equal 'quote_verifying',assert_raises(R::Error){submit(item,side:'long')}.code
      R::Exchange.process(item.id);assert_equal 'pending',close.reload.status
      travel 10.seconds;accept(item,'1');R::Exchange.process(item.id)
      assert_equal 'filled',close.reload.status
      assert_equal 'yahoo',close.details.dig('execution_quote','source')
      assert close.details['executed_at']
      assert_equal 0,R::Position.count
      assert_equal 0,R::Entry.sum(:units)
    end
  end
  def test_refresh_rechecks_once_then_reuses_symbol_cooldown
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(provider:'yahoo',provider_symbol:'JPY=X',quote:observation('0.15'))
      SiteSetting.rsc_market_data_enabled=true;SiteSetting.rsc_twelve_data_api_key=''
      old=R::MarketData.method(:fetch_primary_quote);calls=0
      R::MarketData.define_singleton_method(:fetch_primary_quote) { |_|calls+=1;observation= {'price'=>'0.1503','source'=>'yahoo','source_time'=>Time.current.iso8601,'received_at'=>Time.current.iso8601,'pricing_method'=>R::MarketData::FX_PRICING,'delay_seconds'=>0,'session_start'=>1.hour.ago.iso8601,'session_end'=>8.hours.from_now.iso8601};observation }
      travel 30.seconds;R::MarketData.refresh_if_needed(item.id,purpose: :trade)
      assert_equal 2,calls
      assert G.pending?(item.reload.quote)
      R::MarketData.refresh_if_needed(item.id,purpose: :trade)
      assert_equal 2,calls
    ensure
      R::MarketData.define_singleton_method(:fetch_primary_quote,old) if old
    end
  end
  def test_reported_6193_source_switch_cannot_fill_pending_short
    travel_to(Time.utc(2026,10,28,17,25,26)) do
      fund(@alice,'5000');activity;item=forex
      item.update!(quote:observation('0.150276508776148112',at:Time.utc(2026,10,28,17,24,17)))
      order=submit(item,side:'short',quantity:'400000')
      travel_to(Time.utc(2026,10,28,17,29,32))
      accept(item,'0.150010500735051453',source:'twelve_data',at:Time.utc(2026,10,28,17,28))
      assert G.pending?(item.quote)
      R::Exchange.process(item.id)
      assert_equal 'pending',order.reload.status
      assert_equal 0,R::Position.count
      assert_empty item.history
      R::Exchange.cancel(actor:@alice,order_id:order.id,request_id:'cancel-reviewed')
      assert_equal '5000',R::Account.wallet(@alice.id).balance
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def test_failed_backup_keeps_quarantine_without_consuming_money
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(provider:'yahoo',provider_symbol:'CNY=X',quote:observation('0.15'))
      travel 10.seconds;accept(item,'0.1503')
      primary=R::MarketData.method(:fetch_primary_quote);backup=R::MarketData.method(:forex_fallback)
      SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
      q=observation('0.1503')
      R::MarketData.define_singleton_method(:fetch_primary_quote){|_|q}
      R::MarketData.define_singleton_method(:forex_fallback){|_|raise R::Error.new('provider_busy')}
      R::MarketData.verify_forex_quote(item)
      assert G.pending?(item.reload.quote)
      assert_equal '0.15',item.quote['price']
      assert_equal 'provider_busy',item.quote.dig('verification','backup_error')
    ensure
      R::MarketData.define_singleton_method(:fetch_primary_quote,primary) if primary
      R::MarketData.define_singleton_method(:forex_fallback,backup) if backup
      SiteSetting.rsc_twelve_data_api_key=''
    end
  end

  def test_conflict_survives_expired_samples_and_backup_can_take_over
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(quote:observation('0.1503'))
      travel 10.seconds;accept(item,'0.15',source:'twelve_data')
      assert G.pending?(item.quote)
      travel 6.minutes
      3.times do
        accept(item,'0.1503');assert G.pending?(item.quote)
        travel 60.seconds
      end
      3.times do |n|
        # The backup timestamp is older than the primary, but still usable.
        accept(item,'0.1503')
        accept(item,'0.15',source:'twelve_data',at:100.seconds.ago)
        assert G.pending?(item.quote) if n<2
        travel 60.seconds if n<2
      end
      refute G.pending?(item.quote)
      assert_equal 'backup_consensus',item.quote.dig('verification','method')
      assert_equal 'twelve_data',item.quote.dig('verification','preferred_source')
      assert_equal '0.15',item.quote['price']
      accept(item,'0.1503')
      assert_equal '0.15',item.quote['price']
      assert_equal 'twelve_data',item.quote['source']
      accept(item,'0.15001')
      assert_equal 'cross_source',item.quote.dig('verification','method')
      assert_nil item.quote.dig('verification','preferred_source')
    end
  end

  def test_minute_sample_freshness_is_bounded_and_matches_execution
    travel_to(Time.utc(2026,10,28,12)) do
      item=forex;item.update!(quote:observation('0.15',source:'twelve_data',at:150.seconds.ago))
      assert G.fresh?(item.quote)
      assert_equal R::Amount.parse('0.15'),R::Exchange.price!(item,trading:true)
      assert R::MarketListing.tradable?(R::MarketListing.rows([item],execution:false).first)
      travel 31.seconds
      refute G.fresh?(item.quote)
      assert_equal 'quote_stale',assert_raises(R::Error){R::Exchange.price!(item)}.code
    end
  end

end
