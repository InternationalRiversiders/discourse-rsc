# frozen_string_literal: true
require '/rsc/test/forex_primary_policy_test'

class AutomaticProtectionFallbackTest < ForexPrimaryPolicyTest
  ForexPrimaryPolicyTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  B = R::FallbackBudget

  def setup
    super
    Discourse.cache.delete('rsc:fx-fallback:v1:BRL')
    Discourse.redis.del('rsc:fx-fallback:slot', 'rsc:fx-fallback:retry:BRL', "rsc:fx-fallback:requests:#{Time.current.utc.to_date}")
  end

  def protected_position(side: 'long', tp: '1.0003', sl: '0.9997')
    activity
    fund
    item=live_fx(G.accepted(observation('1'),'continuous'))
    opening=submit(item,side:side,quantity:'100',leverage:1)
    assert_equal 'filled',opening.status
    position=R::Position.find_by!(instrument_id:item.id,user_id:@alice.id)
    R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:tp,stop_loss:sl,request_id:SecureRandom.uuid)
    stale=item.quote.merge('source_time'=>5.minutes.ago.iso8601,'received_at'=>5.minutes.ago.iso8601)
    item.update!(quote:stale,synced_at:5.minutes.ago)
    [item,position,stale]
  end

  # Exercise the real shared budget, cache, quote guard and fill pipeline.
  def with_backup_feed(primary, price)
    old_primary=R::MarketData.method(:fetch_primary_quote)
    old_http=R::ProviderHttp.method(:get)
    R::MarketData.define_singleton_method(:fetch_primary_quote){|_| primary}
    calls=[]
    R::ProviderHttp.define_singleton_method(:get) do |host,path,params|
      raise "Unexpected provider #{host} #{path}" unless host=='api.twelvedata.com' && path=='/exchange_rate'
      calls << params[:symbol]
      raise price if price.is_a?(Exception)
      {'symbol'=>params[:symbol],'rate'=>(BigDecimal('1')/BigDecimal(price)).to_s('F'),'timestamp'=>Time.current.to_i}
    end
    yield calls
  ensure
    R::MarketData.define_singleton_method(:fetch_primary_quote,old_primary)
    R::ProviderHttp.define_singleton_method(:get,old_http)
  end

  def poll
    R::MarketData.sync_forex { |id| R::Exchange.process(id) }
  end

  [['long','1.0003','0.9997','1.0004','stock_take_profit'],
   ['long','1.0003','0.9997','0.9996','stock_stop_loss'],
   ['short','0.9997','1.0003','0.9996','stock_take_profit'],
   ['short','0.9997','1.0003','1.0004','stock_stop_loss']].each do |side,tp,sl,price,reason|
    define_method("test_stale_primary_#{side}_#{reason}_uses_backup_and_closes_once") do
      travel_to(Time.utc(2026,11,3,12)) do
        item,position,stale=protected_position(side:side,tp:tp,sl:sl)
        with_backup_feed(stale,price) do |calls|
          poll
          refute R::Position.exists?(position.id)
          closing=R::Order.where(side:'close').sole
          assert_equal 'filled',closing.status
          assert_equal reason,closing.details['reason']
          assert_equal 'twelve_data',closing.details.dig('execution_quote','source')
          poll
          R::Exchange.process(item.id)
          assert_equal 1,R::Order.where(side:'close').count
          assert_equal ['USD/BRL'],calls
          assert_equal 1,B.report[:total_reserved]
          assert_equal ['position_risk'],B.report[:rows].map{|r|r[:operation]}.uniq
          assert_equal 0,R::Entry.sum(:units)
        end
      end
    end
  end

  def test_fresh_primary_triggers_stop_without_any_backup_call
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,_=protected_position
      with_backup_feed(observation('1.0004'),R::Error.new('provider_daily_limit')) do |calls|
        poll
        refute R::Position.exists?(position.id)
        assert_empty calls
        assert_equal 'yahoo',R::Order.where(side:'close').sole.details.dig('execution_quote','source')
      end
    end
  end

  def test_checks_share_valid_quote_and_clearing_stops_keeps_liquidation_monitoring
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=protected_position(tp:'1.01',sl:'0.99')
      with_backup_feed(stale,'1.0001') do |calls|
        poll; poll
        assert_equal ['USD/BRL'],calls
        assert R::Position.exists?(position.id)
        assert_equal 0,R::Order.where(side:'close').count
        R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:nil,stop_loss:nil,request_id:SecureRandom.uuid)
        travel 4.minutes
        Discourse.redis.del('rsc:fx-fallback:slot')
        item.update!(quote:stale,synced_at:5.minutes.ago)
        poll
        assert_equal ['USD/BRL','USD/BRL'],calls
        B.with_context(:execution){assert B.allowed?(item)}
      end
    end
  end

  def test_frozen_wallet_and_page_views_do_not_grant_protection_budget
    travel_to(Time.utc(2026,11,3,12)) do
      item,_,stale=protected_position
      [nil,:read,:background,:forex_fast,:protection].each do |purpose|
        B.with_context(purpose){refute B.allowed?(item)}
      end
      B.with_context(:execution){assert B.allowed?(item)}
      R::Account.wallet(@alice.id).update!(status:'frozen')
      with_backup_feed(stale,'1.0004') do |calls|
        poll
        assert_empty calls
        B.with_context(:execution){refute B.allowed?(item)}
        B.with_context(:forex_review){refute B.allowed?(item)}
      end
    end
  end

  def test_backup_failure_does_not_close_at_an_old_or_unverified_price
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=protected_position
      with_backup_feed(stale,R::Error.new('provider_unavailable')) do |calls|
        before=R::Account.wallet(@alice.id).balance
        poll; poll
        assert_equal ['USD/BRL'],calls
        assert R::Position.exists?(position.id)
        assert_equal 0,R::Order.where(side:'close').count
        assert_equal before,R::Account.wallet(@alice.id).balance
      end
    end
  end

  def test_suspect_price_needs_independent_review_before_automatic_close
    travel_to(Time.utc(2026,11,3,12)) do
      item,position,stale=protected_position
      with_backup_feed(stale,'1.002') do |calls|
        3.times do |n|
          Discourse.redis.del('rsc:fx-fallback:slot',"rsc:fx-review:#{item.id}")
          poll
          assert R::Position.exists?(position.id) if n<2
          travel 60.seconds if n<2
        end
        assert_equal 3,calls.size
        refute R::Position.exists?(position.id)
        assert_equal 'stock_take_profit',R::Order.where(side:'close').sole.details['reason']
        assert B.report[:rows].any?{|r|r[:operation]=='position_risk_review' && r[:outcome]=='requests'}
        assert_equal 0,R::Entry.sum(:units)
      end
    end
  end

  def test_general_market_poll_also_selects_position_risk
    travel_to(Time.utc(2026,11,3,12)) do
      _,position,stale=protected_position
      with_backup_feed(stale,'0.9996') do |calls|
        R::MarketData.sync { |id| R::Exchange.process(id) }
        assert_equal ['USD/BRL'],calls
        refute R::Position.exists?(position.id)
        assert_equal 'stock_stop_loss',R::Order.where(side:'close').sole.details['reason']
      end
    end
  end
end
