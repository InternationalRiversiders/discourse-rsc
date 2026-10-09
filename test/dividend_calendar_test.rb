# frozen_string_literal: true
require '/rsc/test/dividends_test'
class DividendCalendarTest < DividendsTest
  DividendsTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  DATE = Date.new(2026, 10, 9)
  def calendar(amount = '2', symbol = 'DEMO')
    {'status'=>{'rCode'=>200}, 'data'=>{'calendar'=>{'asOf'=>'Fri, Oct 9, 2026', 'rows'=>[
      {'symbol'=>symbol, 'dividend_Ex_Date'=>'10/09/2026', 'dividend_Rate'=>amount}
    ]}}}
  end
  def ingest(response = calendar)
    R::DividendCalendar.ingest(DATE, response)
  end
  def test_calendar_discovers_without_admin_and_settles_once_after_ex_day_confirmation
    before_ex do
      fund; item=stock; position=open_stock(item); ingest
      event=R::Dividend.sole
      assert_equal 'approved',event.status
      assert_equal 'nasdaq',event.source
      assert_nil event.reviewed_by_id
      ingest
      assert_equal 1,R::Dividend.count
      assert_equal 1,R::Audit.where(action:'dividend_auto_scheduled').count
      after_ex(item)
      assert_equal 'dividend_pending',assert_raises(R::Error) { R::Exchange.process(item.id) }.code
      assert_equal 0,position.reload.dividend_units
      ingest
      2.times { R::Exchange.process(item.id) }
      assert_equal R::Amount.parse('2'),position.reload.dividend_units
      assert_equal 1,R::DividendEntry.count
      assert_equal 'applied',event.reload.status
    end
  end
  def test_calendar_matches_provider_symbol_and_excludes_ineligible_or_special_distributions
    before_ex do
      item=stock; item.update!(symbol:'US:APPLE',provider_symbol:'AAPL')
      ingest(calendar('2','APPLE')); assert_equal 0,R::Dividend.count
      ingest(calendar('25','AAPL')); assert_equal 0,R::Dividend.count
      item.update!(currency:'CNY'); ingest(calendar('2','AAPL')); assert_equal 0,R::Dividend.count
      item.update!(currency:'USD'); ingest(calendar('2','AAPL'))
      assert_equal item.id,R::Dividend.sole.instrument_id
    end
  end
  def test_calendar_refuses_duplicate_missing_or_invalid_data_without_writing_money
    before_ex do
      item=stock; ingest
      bad=calendar; bad['data']['calendar']['rows'] << bad['data']['calendar']['rows'].first.dup
      ingest(bad); assert_equal 'invalid_or_duplicate',R::Dividend.sole.source_issue
      bad['data']['calendar']['rows']=[]
      ingest(bad); assert_equal 'missing_from_source',R::Dividend.sole.source_issue
      bad['data']['calendar']['rows']=nil
      assert_raises(R::Error) { ingest(bad) }
      bad=calendar; bad['data']['calendar']['asOf']='Thu, Oct 8, 2026'
      assert_raises(R::Error) { ingest(bad) }
      ingest(calendar('NaN')); assert_equal 'invalid_or_duplicate',R::Dividend.sole.source_issue
      ingest(calendar('2.000000001')); assert_equal 'invalid_or_duplicate',R::Dividend.sole.source_issue
      assert_equal 0,R::DividendEntry.count
      assert_equal 0,R::Entry.count
      ingest; assert_nil R::Dividend.sole.source_issue
    end
  end
  def test_calendar_amends_future_amounts_but_blocks_conflicting_late_corrections
    before_ex do
      fund;item=stock;position=open_stock(item);ingest
      ingest(calendar('3')); assert_equal R::Amount.parse('3'),R::Dividend.sole.per_share_units
      after_ex(item,'97'); ingest(calendar('4'))
      assert_equal 'changed_after_ex_date',R::Dividend.sole.source_issue
      assert_equal 'dividend_pending',assert_raises(R::Error) { R::Exchange.process(item.id) }.code
      assert_equal 0,position.reload.dividend_units
      ingest(calendar('3'));R::Exchange.process(item.id)
      assert_equal R::Amount.parse('3'),position.reload.dividend_units
    end
  end
  def test_calendar_does_not_backfill_or_overwrite_manual_canceled_or_applied_plans
    before_ex do
      item=stock; event=schedule(item,'5')
      ingest;assert_equal R::Amount.parse('5'),event.reload.per_share_units
      event.destroy!
      ingest;event=R::Dividend.sole
      R::Dividends.review(actor:@admin,id:event.id,decision:'canceled',version:event.lock_version,request_id:SecureRandom.uuid)
      ingest;assert_equal 'canceled',event.reload.status
      event.destroy!
      after_ex(item);ingest;assert_equal 0,R::Dividend.count
    end
  end
  def test_calendar_disabled_switch_stops_discovery_but_keeps_confirming_obligations
    before_ex do
      stock;SiteSetting.rsc_dividends_enabled=false
      ingest;assert_equal 0,R::Dividend.count
      SiteSetting.rsc_dividends_enabled=true;ingest
      SiteSetting.rsc_dividends_enabled=false
      assert_equal [DATE],R::DividendCalendar.dates
      travel_to(Time.utc(2026,10,9,12));ingest
      assert R::DividendCalendar.confirmed?(R::Dividend.sole)
    end
  end
  def test_calendar_ex_date_price_drop_does_not_reclassify_an_approved_distribution
    before_ex do
      fund; item=stock; position=open_stock(item)
      ingest(calendar('20'))
      after_ex(item,'80'); ingest(calendar('20')); R::Exchange.process(item.id)
      assert_equal R::Amount.parse('20'),position.reload.dividend_units
      assert_equal '10',R::Views.position(position)[:equity]
    end
  end
  def test_calendar_uses_cache_only_after_success_and_failed_fetch_can_retry
    before_ex do
      stock
      key="rsc:dividend-calendar:#{DATE}";Discourse.redis.del(key)
      original=R::ProviderHttp.method(:get); calls=0
      R::ProviderHttp.define_singleton_method(:get) { |*| calls+=1; raise R::Error.new('provider_unavailable') if calls == 1; calendar = {'status'=>{'rCode'=>200},'data'=>{'calendar'=>{'asOf'=>'Fri, Oct 9, 2026','rows'=>[]}}}; calendar }
      begin
        assert_raises(R::Error) { R::DividendCalendar.sync(DATE) }
        assert_nil Discourse.redis.get(key)
        2.times { R::DividendCalendar.sync(DATE) }
        assert_equal 2,calls
        assert Discourse.redis.get(key)
      ensure
        R::ProviderHttp.define_singleton_method(:get,original)
        Discourse.redis.del(key)
      end
    end
  end
end
