# frozen_string_literal: true
require '/rsc/test/forex_quote_guard_test'
class ForexPrimaryPolicyTest < ForexQuoteGuardTest
  ForexQuoteGuardTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def with_feeds(primary, backup)
    old_primary=R::MarketData.method(:fetch_primary_quote)
    old_backup=R::MarketData.method(:forex_fallback)
    calls={primary:0,backup:0}
    R::MarketData.define_singleton_method(:fetch_primary_quote) do |_|
      calls[:primary]+=1
      raise primary if primary.is_a?(Exception)
      primary
    end
    R::MarketData.define_singleton_method(:forex_fallback) do |_|
      calls[:backup]+=1
      raise backup if backup.is_a?(Exception)
      backup
    end
    yield calls
  ensure
    R::MarketData.define_singleton_method(:fetch_primary_quote,old_primary)
    R::MarketData.define_singleton_method(:forex_fallback,old_backup)
  end

  def live_fx(previous)
    item=forex('FX:BRL')
    item.update!(provider:'yahoo',provider_symbol:'BRL=X',quote:previous,synced_at:1.minute.ago)
    SiteSetting.rsc_market_data_enabled=true
    SiteSetting.rsc_twelve_data_api_key='isolated-test-key'
    item
  end

  def teardown
    SiteSetting.rsc_twelve_data_api_key=''
    super
  end

  def test_normal_primary_never_calls_backup_in_any_refresh_path
    travel_to(Time.utc(2026,10,30,17,30,46)) do
      item=live_fx(observation('0.18385',at:30.seconds.ago).merge('received_at'=>30.seconds.ago.iso8601))
      with_feeds(observation('0.18388'),R::Error.new('provider_daily_limit')) do |calls|
        %i[read trade exit execution forex_fast background protection].each do |purpose|
          R::MarketData.refresh_if_needed(item.id,purpose:purpose)
          refute G.pending?(item.reload.quote)
          assert_equal 'yahoo',item.quote['source']
        end
        assert_operator calls[:primary],:>=,1
        assert_equal 0,calls[:backup]
      end
    end
  end

  def test_order_6497_normal_primary_is_not_blocked_by_older_backup
    travel_to(Time.utc(2026,10,30,17,30,46)) do
      # Actual accepted reference and follow-up quote from the slow BRL order.
      backup=observation('0.183771168141430291',source:'twelve_data',at:Time.utc(2026,10,30,17,28))
      backup['received_at']=Time.utc(2026,10,30,17,30,16).iso8601
      backup['verification']={'version'=>2,'status'=>'verified','preferred_source'=>'twelve_data',
        'observations'=>{'twelve_data'=>[backup.slice(*G::FIELDS)]}}
      incoming=observation('0.183884373505939465',at:Time.utc(2026,10,30,17,30,45))
      item=live_fx(backup)
      fund;activity
      # Replay a legacy queued opening after normal primary service resumes.
      order=R::Order.create!(user_id:@alice.id,instrument_id:item.id,side:'short',leverage:100,
        quantity_units:R::Amount.parse('100'),reserved_units:0,status:'pending',
        created_at:Time.utc(2026,10,30,17,30,30),execute_at:Time.utc(2026,10,30,17,30,30),
        expires_at:10.minutes.from_now,details:{'reference_price'=>backup['price'],'fee_bps'=>0,'fx_confirmation'=>true})
      reserve=R::Amount.parse('1')
      R::Commands.move(user_id:@alice.id,action:'stock_reserve',request_id:'brl-regression-reserve',
        postings:{R::Account.wallet(@alice.id).id=>-reserve,R::Account.internal("order:#{order.id}").id=>reserve})
      order.update!(reserved_units:reserve)
      with_feeds(incoming,R::Error.new('provider_daily_limit')) do |calls|
        R::MarketData.refresh_if_needed(item.id,purpose: :execution)
        assert_equal 0,calls[:backup]
        refute G.pending?(item.reload.quote)
        assert_equal 'primary_resumed',item.quote.dig('verification','method')
        assert_nil item.quote.dig('verification','preferred_source')
        R::Exchange.process(item.id)
        assert_equal 'filled',order.reload.status
        assert_equal incoming['price'],order.details['price']
        assert_equal 0,R::Entry.sum(:units)
      end
    end
  end

  def test_legacy_cross_source_only_quarantine_recovers_without_backup
    travel_to(Time.utc(2026,10,30,12)) do
      previous=observation('0.15',at:30.seconds.ago)
      previous['verification']={'version'=>2,'status'=>'pending','reason'=>'source_disagreement','disputed'=>true,
        'observations'=>{'twelve_data'=>[observation('0.1498',source:'twelve_data',at:100.seconds.ago).slice(*G::FIELDS)]}}
      item=live_fx(previous)
      with_feeds(observation('0.15001'),R::Error.new('provider_daily_limit')) do |calls|
        R::MarketData.refresh_if_needed(item.id,purpose: :trade)
        refute G.pending?(item.reload.quote)
        assert_equal 'primary_recovered',item.quote.dig('verification','method')
        assert_equal 0,calls[:backup]
      end
    end
  end

  def test_actual_primary_jump_still_calls_backup_and_cannot_execute
    travel_to(Time.utc(2026,10,30,12)) do
      item=live_fx(observation('0.15',at:30.seconds.ago).merge('received_at'=>30.seconds.ago.iso8601))
      with_feeds(observation('0.1503'),R::Error.new('provider_daily_limit')) do |calls|
        R::MarketData.refresh_if_needed(item.id,purpose: :trade)
        assert_equal 1,calls[:backup]
        assert G.pending?(item.reload.quote)
        assert_equal '0.15',item.quote['price']
        assert_equal 'quote_verifying',assert_raises(R::Error){R::Exchange.price!(item)}.code
        assert_equal 'provider_daily_limit',item.quote.dig('verification','backup_error')
      end
    end
  end

  def test_stale_or_unavailable_primary_still_uses_backup_for_execution
    travel_to(Time.utc(2026,10,30,12)) do
      stale=observation('0.15',at:5.minutes.ago).merge('received_at'=>5.minutes.ago.iso8601)
      [stale,R::Error.new('provider_unavailable')].each do |primary|
        item=live_fx(stale)
        with_feeds(primary,observation('0.15001',source:'twelve_data',at:100.seconds.ago)) do |calls|
          R::MarketData.refresh_if_needed(item.id,purpose: :exit)
          assert_equal 1,calls[:backup]
          assert_equal 'twelve_data',item.reload.quote['source']
          assert_equal R::Amount.parse('0.15001'),R::Exchange.price!(item,trading:true)
        end
        item.destroy!
      end
    end
  end

  def test_verified_backup_is_reused_until_stale_when_primary_is_unavailable
    travel_to(Time.utc(2026,10,30,12)) do
      backup=G.accepted(observation('0.15',source:'twelve_data',at:100.seconds.ago),'backup_consensus',preferred:'twelve_data')
      item=live_fx(backup)
      with_feeds(R::Error.new('provider_unavailable'),observation('0.15001',source:'twelve_data')) do |calls|
        R::MarketData.refresh_if_needed(item.id,purpose: :execution)
        assert_equal 0,calls[:backup]
        assert_equal 'twelve_data',item.reload.quote['source']
        travel 81.seconds
        Discourse.redis.del("rsc:fx-review:#{item.id}")
        R::MarketData.refresh_if_needed(item.id,purpose: :execution)
        assert_equal 1,calls[:backup]
        assert G.fresh?(item.reload.quote)
      end
    end
  end
  def test_current_verified_forex_opens_and_closes_without_provider_requests
    travel_to(Time.utc(2026,10,30,12)) do
      fund;activity
      %w[yahoo twelve_data].each do |source|
        snapshot=G.accepted(observation('1',source:source,at:60.seconds.ago),'continuous')
        item=live_fx(snapshot)
        with_feeds(R::Error.new('provider_busy'),R::Error.new('provider_daily_limit')) do |calls|
          opening=submit(item,quantity:'90000')
          assert_equal 'filled',opening.status
          assert_equal '1',opening.details['price']
          assert_equal source,opening.details.dig('execution_quote','source')
          assert_equal '900',opening.details['margin']
          assert_equal '9',opening.details['fee']
          assert_equal 0,opening.reserved_units.to_i
          assert_equal '91',R::Account.wallet(@alice.id).balance
          assert_equal 'immediate',R::MarketListing.rows([item]).first[:execution_mode]
          closing=submit(item,side:'close',quantity:'90000')
          assert_equal 'filled',closing.status
          assert_equal({primary:0,backup:0},calls)
          assert_equal 0,R::Entry.sum(:units)
        end
        # The next source gets its own clean balance and symbol.
        break if source=='twelve_data'
        fund(@alice,'18')
        item.update!(symbol:'FX:OLD-BRL')
      end
    end
  end

  def test_submission_rechecks_expiry_under_the_transaction_lock
    travel_to(Time.utc(2026,10,30,12)) do
      fund;activity
      item=live_fx(G.accepted(observation('1',at:119.seconds.ago),'continuous'))
      original=R::MarketData.method(:refresh_if_needed)
      clock=self
      R::MarketData.define_singleton_method(:refresh_if_needed) do |id,**options|
        result=original.call(id,**options)
        clock.travel 2.seconds
        result
      end
      with_feeds(R::Error.new('provider_busy'),R::Error.new('provider_daily_limit')) do |calls|
        assert_equal 'quote_stale',assert_raises(R::Error){submit(item)}.code
        assert_equal({primary:0,backup:0},calls)
        assert_equal 0,R::Order.count
        assert_equal '1000',R::Account.wallet(@alice.id).balance
      end
    ensure
      R::MarketData.define_singleton_method(:refresh_if_needed,original) if original
    end
  end

  def test_background_polling_still_updates_valid_forex_quotes
    travel_to(Time.utc(2026,10,30,12)) do
      prior=G.accepted(observation('1',at:60.seconds.ago).merge('received_at'=>60.seconds.ago.iso8601),'continuous')
      item=live_fx(prior)
      with_feeds(observation('1.0001'),R::Error.new('provider_daily_limit')) do |calls|
        R::MarketData.refresh_if_needed(item.id,purpose: :execution)
        assert_operator calls[:primary],:>=,1
        assert_equal 0,calls[:backup]
        assert_equal '1.0001',item.reload.quote['price']
      end
    end
  end

end
