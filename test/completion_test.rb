# frozen_string_literal: true
class CompletionTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def with_provider(response)
    original = R::ProviderHttp.method(:get)
    R::ProviderHttp.define_singleton_method(:get) { |*args, **kwargs| response.respond_to?(:call) ? response.call(*args, **kwargs) : response.deep_dup }
    yield
  ensure
    R::ProviderHttp.define_singleton_method(:get, original)
  end

  def reset_to(amount, clear: false, id: SecureRandom.uuid)
    R::Administration.perform(actor: @admin, action: 'reset_assets', request_id: id,
      input: {'user_id'=>@alice.id, 'amount'=>amount, 'reset_mode'=>'total_equity', 'clear_positions'=>clear, 'reason'=>'isolated reset'})
  end

  def retain_assets
    fund
    stock = instrument
    R::Exchange.submit(actor:@alice,instrument_id:stock.id,side:'long',quantity:'1',leverage:5,request_id:SecureRandom.uuid)
    R::Sports.predict(actor:@alice,match_id:match.id,pick:'home',stake:'10',request_id:SecureRandom.uuid)
  end

  def test_total_equity_reset_preserves_positions_predictions_and_frozen_status
    retain_assets
    R::Account.wallet(@alice.id).update!(status:'frozen')
    result = reset_to('100',id:'total-equity-reset')
    assert_equal '70', result['balance']
    assert_equal '30', result['retained_assets']
    assert_equal 'frozen', R::Account.wallet(@alice.id).status
    assert_equal 1, R::Position.count
    assert_equal 1, R::Prediction.where(status:'pending').count
    assert reset_to('100',id:'total-equity-reset')['replayed']
    assert_equal 0, R::Entry.sum(:units)
  end

  def test_invalid_equity_reset_rolls_back_even_position_clearing
    retain_assets
    before = [R::Account.wallet(@alice.id).balance,R::Position.count,R::Entry.count,R::Command.count]
    error = assert_raises(R::Error) { reset_to('9',clear:true) }
    assert_equal 'reset_below_retained', error.code
    assert_equal before, [R::Account.wallet(@alice.id).balance,R::Position.count,R::Entry.count,R::Command.count]
    assert_equal '90', reset_to('100',clear:true)['balance']
    assert_equal 0, R::Position.count
  end

  def test_public_packet_is_minimal_and_expiry_preview_never_moves_money
    fund
    result=R::RedPackets.create(actor:@alice,mode:'fixed',count:3,amount:'2',request_id:SecureRandom.uuid)
    packet=R::Packet.find_by!(token:result['token']);packet.update!(expires_at:1.minute.ago)
    session=ActionDispatch::Integration::Session.new(Rails.application);session.host!('rsc.test');session.https!
    before=[R::Journal.count,R::Account.wallet(@alice.id).balance]
    session.get "/rsc/packet/#{packet.token}/public.json"
    assert_equal 200,session.response.status,session.response.body
    body=JSON.parse(session.response.body)
    assert_equal %w[claimed_count count expires_at message preview sender sender_user status token total],body.keys.sort
    assert_equal %w[avatar_template id username],body['sender_user'].keys.sort
    assert_equal @alice.id,body['sender_user']['id']
    assert_equal 'expired',body['status']
    assert_equal before,[R::Journal.count,R::Account.wallet(@alice.id).balance]
    assert_equal 'open',packet.reload.status
    session.get "/rsc/packet/#{packet.token}.json"
    assert_includes [401,403],session.response.status
    SiteSetting.login_required=true
    session.get "/rsc/packet/#{packet.token}/public.json"
    assert_includes [302,401,403],session.response.status
  ensure
    SiteSetting.login_required=false
  end

  def test_unified_activity_filters_paginate_before_loading_and_hide_allocations
    fund
    R::Wallet.transfer(actor:@alice,recipient:@bob,amount:'1.25',request_id:SecureRandom.uuid)
    25.times do |n|
      R::LegacyRecord.create!(source_table:'transfers',source_id:n.to_s,data:{from_discourse_user_id:@alice.id,to_discourse_user_id:@bob.id,amount_rsc:'2',status:'failed',created_at:n.days.ago.iso8601})
    end
    first=R::AdminReports.activity(kind:'transfer',query:@alice.username)
    assert_equal 26,first[:pagination][:total]
    assert_equal 20,first[:rows].size
    assert_equal 6,R::AdminReports.activity(kind:'transfer',query:@alice.id.to_s,page:2)[:rows].size
    assert_equal 25,R::AdminReports.activity(kind:'transfer',status:'failed')[:pagination][:total]
    assert_equal 1,R::AdminReports.activity(kind:'transfer',status:'success')[:pagination][:total]
    R::RedPackets.create(actor:@alice,mode:'fixed',count:3,amount:'2',request_id:SecureRandom.uuid)
    row=R::AdminReports.activity(kind:'red_packet')[:rows].first
    refute row['packet'].key?(:allocations)
    assert_equal @alice.username,row['sender']
  end

  def test_search_demand_combines_legacy_and_native
    R::LegacyRecord.create!(source_table:'market_search_requests',source_id:'search1',data:{query:'AAPL',discourse_user_id:@alice.id,result_count:0,created_at:1.day.ago.iso8601})
    R::Search.create!(query:'AAPL',user_id:@bob.id,result_count:1,created_at:Time.current)
    row=R::AdminReports.search_demand[:rows].first
    assert_equal 'aapl',row['query']
    assert_equal 2,row['count']
    assert_equal 2,row['users']
    assert_equal 1,row['empty_results']
  end

  def test_admin_activity_includes_historical_issuance_and_signed_resets
    R::LegacyRecord.create!(source_table:'coin_issuances',source_id:'1',data:{discourse_user_id:@alice.id,issued_by_discourse_user_id:@admin.id,amount_rsc:'15',reason:'legacy issuance',status:'success',created_at:Time.current.iso8601})
    R::LegacyRecord.create!(source_table:'point_account_asset_reset_events',source_id:'1',data:{discourse_user_id:@alice.id,changed_by_discourse_user_id:@admin.id,balance_before_rsc:'15',balance_after_rsc:'3',reason:'legacy reset',created_at:Time.current.iso8601})
    row=R::AdminReports.activity(kind:'issuance',query:@alice.username)[:rows].first
    assert_equal '15',row['amount']
    assert_equal @admin.username,row['sender']
    assert_equal '-12',R::AdminReports.activity(kind:'admin_adjustment')[:rows].first['amount']
    assert_equal 0,R::Entry.count
  end

  def test_catalog_approval_uses_existing_mapping_and_is_idempotent
    SiteSetting.rsc_market_data_enabled=true
    stock=instrument;stock.update!(provider:'yahoo',provider_symbol:'AAPL')
    request=R::MarketRequest.create!(user_id:@alice.id,symbol:'AAPL')
    args={actor:@admin,symbol:'AAPL',reason:'verified',request_id:'approve-existing'}
    with_provider(->(*) { flunk 'Existing instrument must not contact provider' }) do
      assert_equal stock.id,R::Catalog.approve(**args)['instrument_id']
      assert R::Catalog.approve(**args)['replayed']
    end
    assert_equal 'approved',request.reload.status
    assert_equal 1,R::Instrument.count
    assert_equal 1,R::Audit.where(action:'market_approve').count
  end

  def test_all_legacy_index_aliases_are_mapped_to_provider_codes
    expected={'SPX'=>'^GSPC','NDX'=>'^NDX','DJI'=>'^DJI','RUT'=>'^RUT','CSI300'=>'000300.SS','HSI'=>'^HSI','N225'=>'^N225','DAX'=>'^GDAXI','FTSE100'=>'^FTSE','CAC40'=>'^FCHI','STOXX50'=>'^STOXX50E','ASX200'=>'^AXJO','KOSPI'=>'^KS11','STI'=>'^STI','TSX'=>'^GSPTSE','NIFTY50'=>'^NSEI'}
    expected.each do |code, target|
      assert_equal ['yahoo',target],R::Catalog.provider({'symbol'=>"INDEX:#{code}"})
    end
  end

  def test_currency_units_keep_the_legacy_usd_valuation_direction
    assert_equal ['yahoo','EURUSD=X'],R::Catalog.provider({'symbol'=>'FX:EUR'})
    assert_equal ['yahoo','JPYUSD=X'],R::Catalog.provider({'symbol'=>'FX:JPY'})
    data=JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))
    meta=data['chart']['result'].first['meta']
    meta.merge!('symbol'=>'JPYUSD=X','currency'=>'USD','instrumentType'=>'CURRENCY','regularMarketPrice'=>'0.0067','chartPreviousClose'=>'0.0066')
    with_provider(data) do
      item=R::Catalog.external_candidate('JPYUSD=X')
      assert_equal '0.0067',item[:quote]['price']
      assert_equal 'USD',item[:quote]['local_currency']
      assert_equal 'forex',item[:category]
    end
    refute R::Catalog.supported_external?('EURGBP=X','CURRENCY')
    assert R::Catalog.supported_external?('JPY=X','CURRENCY')
  end

  def test_unreported_yahoo_delay_requires_advancing_live_samples
    base=quote('100').merge('source'=>'yahoo','delay_reported'=>false,'source_time'=>16.minutes.ago.iso8601)
    first=R::MarketData.observe_delay({},base,category:'cn')
    assert_equal 0,first['delay_seconds']
    second=R::MarketData.observe_delay(first,base.merge('source_time'=>15.minutes.ago.iso8601),category:'cn')
    assert second['delay_inferred']
    assert_operator second['delay_seconds'],:>=,900
    stock=instrument;stock.update!(quote:second)
    assert_equal R::Amount.parse('100'),R::Exchange.price!(stock,trading:true)
    assert R::TradingRules.delayed?(stock)
    stopped=R::MarketData.observe_delay(second,base.merge('source_time'=>second['source_time'],'received_at'=>3.minutes.from_now.iso8601),category:'cn')
    assert_equal second['delay_seconds'],stopped['delay_seconds'], 'A frozen feed cannot grow its acceptable delay'
    assert_equal 0,R::MarketData.observe_delay(first,base.merge('source_time'=>15.minutes.ago.iso8601,'delay_reported'=>true),category:'cn')['delay_seconds']
    assert_equal 0,R::MarketData.observe_delay(first,base.merge('source_time'=>2.days.ago.iso8601),category:'cn')['delay_seconds']
    assert_equal 0,R::MarketData.observe_delay(first,base.merge('session_end'=>1.minute.ago.iso8601),category:'cn')['delay_seconds']
  end

  def test_catalog_approval_validates_provider_before_writing
    SiteSetting.rsc_market_data_enabled=true
    args={actor:@admin,symbol:'AAPL',reason:'verified',request_id:'approve-new'}
    with_provider(->(*) { raise R::Error.new('provider_no_data') }) { assert_raises(R::Error) { R::Catalog.approve(**args) } }
    assert_equal 0,R::Instrument.count
    assert_equal 0,R::Command.count
    with_provider(JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))) { R::Catalog.approve(**args) }
    assert_equal 'Apple Inc.',R::Instrument.first.name
    assert_equal '336.13',R::Instrument.first.quote['price']
    assert_equal R::Amount.parse('0.01'),R::Instrument.first.step_units.to_i
    assert_equal 5,R::Instrument.first.fee_bps
  end

  def test_legacy_request_codes_and_unsupported_external_markets
    SiteSetting.rsc_market_data_enabled=true
    request=R::MarketRequest.create!(user_id:@alice.id,symbol:'NASDAQ:AAPL')
    data=JSON.parse(File.read('/rsc/test/fixtures/yahoo-chart.json'))
    with_provider(data) { R::Catalog.approve(actor:@admin,symbol:request.symbol,reason:'legacy request',request_id:'legacy-approval') }
    assert_equal 'approved',request.reload.status
    assert_equal 'AAPL',R::Instrument.first.provider_symbol
    refute R::Catalog.supported_external?('GC=F','FUTURE')
    refute R::Catalog.supported_external?('UNKNOWN','INDEX')
    meta=data['chart']['result'].first['meta'];meta['symbol']='DEMO.TO'
    with_provider(data) do
      error=assert_raises(R::Error) { R::Catalog.external_candidate('DEMO.TO') }
      assert_equal 'market_opening_disabled',error.code
    end
    assert_equal 1,R::Instrument.count
  end

  def test_old_postponed_match_recheck_observes_delay_and_settles_once
    fund
    game=match
    R::Sports.predict(actor:@alice,match_id:game.id,pick:'home',stake:'10',request_id:'old-game')
    game.update!(external_id:'espn:soccer:eng.1:12345',source:'espn',sport:'soccer',league:'eng.1',starts_at:30.days.ago,status:'postponed')
    data={'header'=>{'id'=>'12345','competitions'=>[{'date'=>30.days.ago.iso8601,'status'=>{'type'=>{'completed'=>true,'name'=>'STATUS_FULL_TIME'}},'competitors'=>[
      {'homeAway'=>'home','score'=>'2','team'=>{'displayName'=>'Home'}}, {'homeAway'=>'away','score'=>'1','team'=>{'displayName'=>'Away'}}]}]}}
    with_provider(data) { assert_equal 1,R::SportsData.recheck_pending[:checked] }
    assert_equal 'home',game.reload.result
    assert_equal 0,R::Sports.settle_pending[:settled]
    game.update!(confirmed_at:6.minutes.ago)
    with_provider(data) { R::SportsData.recheck_pending }
    assert_equal 1,R::Sports.settle_pending[:settled]
    assert_equal 0,R::Sports.settle_pending[:settled]
    assert_equal '1010',R::Account.wallet(@alice.id).balance
    assert_equal 0,R::Entry.sum(:units)
  end

  def test_manual_result_is_never_overwritten_by_recheck
    fund;game=match
    R::Sports.predict(actor:@alice,match_id:game.id,pick:'home',stake:'10',request_id:'manual-game')
    game.update!(external_id:'12345',source:'espn',sport:'soccer',league:'fifa.world',starts_at:30.days.ago,provider_data:{manual_result:true})
    with_provider(->(*) { flunk 'Manual result must not contact provider' }) { assert_equal 0,R::SportsData.recheck_pending[:checked] }
  end

  def test_new_admin_routes_keep_permission_and_readonly_guards
    session=ActionDispatch::Integration::Session.new(Rails.application);session.host!('rsc.test');session.https!
    key=ApiKey.create!(user_id:@alice.id,created_by_id:@admin.id,description:'isolated completion test')
    headers={'Api-Key'=>key.key,'Api-Username'=>@alice.username}
    %w[activity search-demand market-lookup].each do |path|
      session.get "/rsc/admin/#{path}.json",headers:headers
      assert_equal 403,session.response.status
    end
    session.post '/rsc/admin/settle.json',headers:headers
    assert_equal 403,session.response.status
    key.destroy!;key=ApiKey.create!(user_id:@admin.id,created_by_id:@admin.id,description:'isolated completion admin')
    headers={'Api-Key'=>key.key,'Api-Username'=>@admin.username}
    SiteSetting.rsc_read_only=true
    %w[activity search-demand].each do |path|
      session.get "/rsc/admin/#{path}.json",headers:headers
      assert_equal 200,session.response.status,session.response.body
    end
    %w[settle market-approve].each do |path|
      session.post "/rsc/admin/#{path}.json",headers:headers
      assert_equal 503,session.response.status
      assert_equal "read_only",JSON.parse(session.response.body)["error_code"]
    end
    assert_equal 0,R::Audit.count
  ensure
    key&.destroy!
    SiteSetting.rsc_read_only=false
  end

  def test_reviewed_orphan_import_preserves_every_coin_without_creating_user
    id=User.maximum(:id)+1000
    tables={'users'=>[{'discourse_user_id'=>id,'username'=>'deleted_legacy'}],
      'point_accounts'=>[{'discourse_user_id'=>id,'balance_rsc'=>'1','status'=>'active'}],
      'reward_payouts'=>[{'discourse_user_id'=>id,'status'=>'success','date'=>'2026-09-20'}]}
    file=Tempfile.new('rsc-quarantine-test');file.write({format:'rsc-native-export-v1',tables:tables}.to_json);file.close
    digest=Digest::SHA256.file(file.path).hexdigest
    review={'source_sha256'=>digest,'quarantine_user_ids'=>[id]}
    assert_raises(R::Error) { R::LegacyImport.run(file.path) }
    assert_raises(R::Error) { R::LegacyImport.run(file.path,identity_review:review.merge('source_sha256'=>'wrong')) }
    report=R::LegacyImport.run(file.path,identity_review:review)
    assert_equal '1',report[:opening_assets]
    assert_equal [id],report[:quarantined_user_ids]
    assert_equal 0,R::Account.count
    SiteSetting.rsc_enabled=false
    R::LegacyImport.run(file.path,apply:true,expected_sha256:digest,identity_review:review)
    account=R::Account.find_by!(key:"legacy-quarantine:#{id}")
    assert_equal 'frozen',account.status
    assert_equal '1',account.balance
    assert_nil account.user_id
    refute User.exists?(id:id)
    assert_equal 0,R::Entry.sum(:units)
    assert R::Command.exists?(key:"daily_reward:#{id}:daily-2026-09-20")
    assert_equal 3,R::LegacyRecord.count
  ensure
    file&.unlink
    SiteSetting.rsc_enabled=true
  end

  def test_orphan_exposure_and_unreviewed_renames_still_abort
    id=User.maximum(:id)+1000
    tables={'users'=>[{'discourse_user_id'=>id}], 'positions'=>[{'discourse_user_id'=>id}]}
    file=Tempfile.new('rsc-identity-test');file.write({format:'rsc-native-export-v1',tables:tables}.to_json);file.close
    digest=Digest::SHA256.file(file.path).hexdigest
    error=assert_raises(R::Error) { R::LegacyImport.run(file.path,identity_review:{'source_sha256'=>digest,'quarantine_user_ids'=>[id]}) }
    assert_equal 'import_quarantine_has_dependencies',error.code
    tables={'users'=>[{'discourse_user_id'=>@alice.id,'username'=>'old_alice'}], 'point_accounts'=>[{'discourse_user_id'=>@alice.id,'balance_rsc'=>'3','status'=>'active'}]}
    File.write(file.path,{format:'rsc-native-export-v1',tables:tables}.to_json)
    assert_raises(R::Error) { R::LegacyImport.run(file.path) }
    digest=Digest::SHA256.file(file.path).hexdigest
    review={'source_sha256'=>digest,'renamed_users'=>{@alice.id.to_s=>{'previous_username'=>'old_alice','current_username'=>@alice.username}}}
    report=R::LegacyImport.run(file.path,identity_review:review)
    assert_equal [@alice.id],report[:renamed_user_ids]
    assert_equal '3',report[:opening_assets]
    assert_equal 0,R::Account.count
  ensure
    file&.unlink
  end
end
