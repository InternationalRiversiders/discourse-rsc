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
    R::MarketData.define_singleton_method(:fetch_primary_quote) do |_|
      raise primary if primary.is_a?(Exception)
      primary.respond_to?(:call) ? primary.call : primary
    end
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
    define_method("test_primary_#{side}_#{reason}_closes_once_without_backup") do
      travel_to(Time.utc(2026,11,4,12)) do
        item,position,stale=protected_position(side:side,tp:tp,sl:sl)
        with_backup_feed(stale,price) do |calls|
          poll;poll
          assert_empty calls
          assert R::Position.exists?(position.id)
          assert_equal 0,R::Order.where(side:'close').count
        end
        with_backup_feed(observation(price),R::Error.new('provider_daily_limit')) do |calls|
          poll
          refute R::Position.exists?(position.id)
          closing=R::Order.where(side:'close').sole
          assert_equal reason,closing.details['reason']
          assert_equal 'yahoo',closing.details.dig('execution_quote','source')
          poll; R::Exchange.process(item.id)
          assert_equal 1,R::Order.where(side:'close').count
          assert_empty calls
          assert_equal 0,B.report[:total_reserved]
          assert_equal 0,R::Entry.sum(:units)
        end
      end
    end
  end

  def test_checks_and_stop_removal_never_authorize_backup
    travel_to(Time.utc(2026,11,4,12)) do
      item,position,stale=protected_position(tp:'1.01',sl:'0.99')
      with_backup_feed(stale,'0.1') do |calls|
        poll
        R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:nil,stop_loss:nil,request_id:SecureRandom.uuid)
        travel 30.minutes
        poll
        assert_empty calls
        assert R::Position.exists?(position.id)
        %i[execution forex_review read background forex_fast protection].each do |purpose|
          B.with_context(purpose){refute B.allowed?(item)}
        end
        assert_equal 0,B.report[:total_reserved]
      end
    end
  end

  def test_general_market_poll_uses_primary_for_protection
    travel_to(Time.utc(2026,11,4,12)) do
      _,position,_=protected_position
      with_backup_feed(observation('0.9996'),'1.001') do |calls|
        R::MarketData.sync { |id| R::Exchange.process(id) }
        assert_empty calls
        refute R::Position.exists?(position.id)
        assert_equal 'stock_stop_loss',R::Order.where(side:'close').sole.details['reason']
      end
    end
  end
end
