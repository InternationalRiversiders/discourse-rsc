# frozen_string_literal: true
require '/rsc/test/business_test'
require '/rsc/db/migrate/20261029160000_store_rsc_catalog_metadata'

class CatalogStateTest < NativeBusinessTest
  NativeBusinessTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def test_legacy_metadata_copied_once_and_database_edits_are_authoritative
    item = instrument
    item.update!(metadata: {'display_symbol'=>'CURRENT'})
    archived = R::LegacyRecord.create!(source_table:'market_instruments',source_id:'31',data:{'id'=>31,'symbol'=>item.symbol,
      'display_symbol'=>'OLD','exchange'=>'SSE','catalog_rank'=>3,'trading_hours'=>'09:30-11:30,13:00-15:00 Asia/Shanghai'})
    StoreRscCatalogMetadata.new.copy_legacy_metadata
    item.reload
    assert_equal 'CURRENT', item.display_symbol
    assert_equal 'SSE', item.exchange
    assert_equal 31, item.metadata['catalog_id']
    assert R::MarketSessions.closed?(item,Time.utc(2026,9,21,3,45))
    archived.update!(data:archived.data.merge('trading_hours'=>'24/7','display_symbol'=>'ARCHIVE CHANGE'))
    Discourse.cache.delete('rsc:trading-hours')
    assert R::MarketSessions.closed?(item,Time.utc(2026,9,21,3,45))
    row=R::MarketListing.rows([item],execution:false).first
    assert_equal 'CURRENT',row[:display_symbol]
    assert_equal 'SSE',row[:exchange]
    assert_equal 3,row[:catalog_rank]
    assert_equal 31,row[:catalog_id]
    assert_equal 0,R::Journal.count
    item.update!(metadata:item.metadata.merge('trading_hours'=>'24/7'))
    refute R::MarketSessions.closed?(item,Time.utc(2026,9,21,3,45))
  end

  def test_instrument_edits_invalidate_listing_cache_without_waiting_for_ttl
    item=instrument
    assert_equal 1,R::MarketListing.catalog.size
    item.update!(name:'Updated name',metadata:{'display_symbol'=>'DISPLAY'})
    assert_equal 'Updated name',R::MarketListing.catalog.first[:name]
    assert_equal 'DISPLAY',R::MarketListing.catalog.first[:display_symbol]
    item.update!(active:false)
    assert_empty R::MarketListing.catalog
    assert_equal({total:1,active:0,inactive:1},R::Instrument.catalog_summary)
  end

  def test_request_status_uses_current_listing_instead_of_historical_approval
    item=instrument
    item.update!(provider_symbol:'AAPL',active:false)
    request=R::MarketRequest.create!(user_id:@alice.id,symbol:'NASDAQ:AAPL',status:'approved',details:{'last_error'=>'旧错误','last_error_code'=>'provider_no_data'})
    row=R::MarketRequest.present([request.as_json]).first
    assert_equal 'approved',row['status']
    assert_equal 'inactive',row['listing_status']
    refute row['can_retry']
    item.update!(active:true)
    row=R::MarketRequest.present([request.as_json]).first
    assert_equal 'listed',row['listing_status']
    assert_equal item.id,row['resolved_instrument_id']
    assert_equal item.name,row['name']
    assert_nil row['listing_error']
  end

  def test_duplicate_alias_routes_to_canonical_but_ordinary_inactive_symbol_stays_disabled
    SiteSetting.rsc_market_data_enabled=true
    keep=instrument
    keep.update!(symbol:'EURONEXT:AIR',provider:'yahoo',provider_symbol:'AIR.PA')
    old=R::Instrument.create!(symbol:'EPA:AIR',name:'Airbus duplicate',provider:'yahoo',provider_symbol:'AIR.PA',active:false,
      metadata:{'canonical_instrument_id'=>keep.id})
    result=R::Catalog.request(actor:@alice,symbol:old.symbol)
    assert_equal keep.id,result['instrument_id']
    assert_equal 2,R::Instrument.count
    refute old.reload.active?
    assert_equal 'listed',R::MarketRequest.present(R::MarketRequest.all.map(&:as_json)).first['listing_status']
    keep.update!(active:false)
    assert_equal 'instrument_inactive',assert_raises(R::Error){R::Catalog.request(actor:@bob,symbol:old.symbol)}.code
  end

  def test_failed_and_never_validated_requests_are_distinct_and_static_seed_is_gone
    failed=R::MarketRequest.create!(user_id:@alice.id,symbol:'MISSING',details:{'last_error_code'=>'provider_no_data'})
    pending=R::MarketRequest.create!(user_id:@alice.id,symbol:'NEW')
    rows=R::MarketRequest.present([failed.as_json,pending.as_json])
    assert_equal %w[failed unlisted],rows.map{|r|r['listing_status']}
    assert rows.all?{|r|r['can_retry']}
    assert_equal 'invalid_admin_action',assert_raises(R::Error){R::Administration.perform(actor:@admin,action:'seed_catalog',input:{'reason'=>'removed'},request_id:'removed-seed')}.code
    assert_equal 0,R::Instrument.count
    refute R::Catalog.respond_to?(:seed)
  end

  def test_market_category_does_not_override_explicit_database_activation
    item=instrument
    item.update!(symbol:'TSX:DEMO',category:'ca',active:false)
    result=R::Administration.perform(actor:@admin,action:'instrument',request_id:'reactivate-db-market',
      input:{'symbol'=>item.symbol,'name'=>item.name,'category'=>'ca','provider'=>'yahoo','provider_symbol'=>'DEMO.TO','active'=>true,'reason'=>'data verified'})
    assert_equal item.id,result['instrument_id']
    assert item.reload.active?
    assert_equal 'ca',item.category
  end

  def test_new_symbols_have_display_exchange_and_local_session_metadata
    meta=R::Catalog.external_metadata('000628.SZ','cn',{'exchangeName'=>'SHZ'})
    assert_equal '000628',meta['display_symbol']
    assert_equal 'SZSE',meta['exchange']
    assert_equal '09:30-11:30,13:00-15:00 Asia/Shanghai',meta['trading_hours']
    assert_equal 'NASDAQ',R::Catalog.external_metadata('AXTI','us',{'exchangeName'=>'NMS'})['exchange']
    assert_equal 'CNY',R::Catalog.external_metadata('CNY=X','forex',{})['display_symbol']
  end
end
