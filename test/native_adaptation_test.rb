# frozen_string_literal: true
require "/rsc/test/readiness_test"
class NativeAdaptationTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def order(stock, quantity: "1", leverage: 5, **extra)
    result=R::Exchange.submit(actor:@alice,instrument_id:stock.id,side:"long",quantity:quantity,leverage:leverage,request_id:SecureRandom.uuid,**extra)
    R::Order.find(result["order_id"])
  end

  def assert_code(code)
    error=assert_raises(R::Error) { yield };assert_equal code,error.code
  end

  def test_crypto_cancellation_window_and_provider_error
    fund;stock=instrument;stock.update!(category:"crypto");pending=order(stock)
    assert_code("cancellation_locked") { R::Exchange.cancel(actor:@alice,order_id:pending.id,request_id:SecureRandom.uuid) }
    pending.update!(created_at:121.seconds.ago)
    R::Exchange.cancel(actor:@alice,order_id:pending.id,request_id:SecureRandom.uuid)
    assert_equal "canceled",pending.reload.status
    pending=order(stock);stock.update!(provider_error:"provider_http_429")
    R::Exchange.cancel(actor:@alice,order_id:pending.id,request_id:SecureRandom.uuid)
    assert_equal "1000",R::Account.wallet(@alice.id).balance
  end

  def test_crypto_hold_uses_latest_open_order_time
    fund;stock=instrument;stock.update!(category:"crypto");pending=order(stock)
    pending.update!(created_at:2.minutes.ago,execute_at:1.second.ago);stock.update!(quote:quote("100"));R::Exchange.process(stock.id)
    position=R::Position.first;assert_operator position.hold_until,:>,Time.current
    assert_code("position_locked") { R::Exchange.submit(actor:@alice,instrument_id:stock.id,side:"close",quantity:"1",leverage:1,request_id:SecureRandom.uuid) }
    assert_in_delta (pending.created_at+5.minutes).to_f,position.hold_until.to_f,0.01
  end

  def test_protection_must_be_profitable_and_precede_liquidation
    fund;stock=instrument;fill(stock,order(stock));position=R::Position.first
    stock.update!(quote:quote("90"))
    assert_code("take_profit_not_profitable") { R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:"95",stop_loss:nil,request_id:SecureRandom.uuid) }
    assert_code("stop_loss_beyond_liquidation") { R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:nil,stop_loss:"70",request_id:SecureRandom.uuid) }
    R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:"120",stop_loss:"86",request_id:SecureRandom.uuid)
    assert_equal R::Amount.parse("86"),position.reload.stop_loss_units
  end

  def test_margin_topup_needs_no_fresh_quote_and_does_not_consume_opening_risk
    fund;stock=instrument;stock.update!(category:"crypto");fill(stock,order(stock));position=R::Position.first
    stock.update!(quote:stock.quote.merge("received_at"=>1.hour.ago.iso8601))
    R::Exchange.add_margin(actor:@alice,position_id:position.id,amount:"500",request_id:SecureRandom.uuid)
    stock.update!(quote:quote("100"))
    assert_equal "pending",order(stock,quantity:"5").status
    assert_equal 0,R::Entry.sum(:units)
  end

  def test_frozen_wallet_preserves_position_and_rejects_protection
    fund;stock=instrument;fill(stock,order(stock));position=R::Position.first
    R::Account.wallet(@alice.id).update!(status:"frozen");stock.update!(quote:quote("1"))
    R::Exchange.process(stock.id);assert R::Position.exists?(position.id)
    assert_code("wallet_frozen") { R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:"200",stop_loss:nil,request_id:SecureRandom.uuid) }
    assert_code("wallet_frozen") { R::Exchange.add_margin(actor:@alice,position_id:position.id,amount:"1",request_id:SecureRandom.uuid) }
    R::Account.wallet(@alice.id).update!(status:"active");R::Exchange.process(stock.id)
    refute R::Position.exists?(position.id)
  end

  def test_stock_minimum_close_only_and_daily_turnover_limits
    fund;stock=instrument;stock.update!(minimum_units:R::Amount.parse("0.001"),step_units:R::Amount.parse("0.001"))
    assert_code("order_notional_below_min") { order(stock,quantity:"0.001") }
    stock.update!(name:"Example 3x leveraged ETF",asset_type:"etf")
    assert_code("market_opening_disabled") { order(stock) }
    stock.update!(name:"Example ordinary shares",asset_type:"stock")
    R::HistoryCache.create!(instrument_id:stock.id,range:"1mo",source:"legacy",currency:"RSC",updated_at:Time.current,candles:20.times.map { |i| {at:(i+1).days.ago.iso8601,close:"100",volume:"10"} })
    assert_code("market_liquidity_limit") { order(stock) }
    assert_equal "filled",order(stock,quantity:"0.01").status
  end

  def test_delayed_stocks_use_portfolio_cap_including_120_second_boundary
    fund;stock=instrument;stock.update!(quote:stock.quote.merge("delay_seconds"=>120))
    assert R::TradingRules.delayed?(stock)
    assert_code("position_risk_limit") { order(stock,quantity:"50",leverage:10) }
  end

  def test_packet_exemption_covers_amount_caps_only_while_effective
    fund(@alice,"10000")
    exemption=R::Exemption.create!(user_id:@alice.id,starts_at:1.day.from_now,expires_at:2.days.from_now,actor_user_id:@admin.id,reason:"Test scheduled exemption")
    assert_code("packet_limit") { R::RedPackets.create(actor:@alice,mode:"fixed",count:4,amount:"100",request_id:SecureRandom.uuid) }
    exemption.update!(starts_at:1.day.ago)
    created=R::RedPackets.create(actor:@alice,mode:"fixed",count:4,amount:"100",request_id:SecureRandom.uuid)
    assert_equal "400",created["total"]
  end

  def test_notifications_identify_actor_and_link_to_specific_packet_once
    fund;packet=R::RedPackets.create(actor:@alice,mode:"fixed",count:2,amount:"1",request_id:SecureRandom.uuid)
    R::RedPackets.claim(actor:@bob,token:packet["token"],request_id:SecureRandom.uuid)
    R::Event.where(kind:%w[red_packet_claim red_packet_claimed_by]).each do |event|
      R::NotificationDelivery.deliver(event);n=Notification.find(event.reload.notification_id)
      assert_equal "/rsc/packets/#{packet['token']}",n.data_hash['river_path'];assert_equal 'rsc',n.data_hash['river_app']
      assert_includes n.data_hash['river_text'],@bob.username if event.kind=='red_packet_claimed_by'
      R::NotificationDelivery.deliver(event);assert_equal n.id,event.reload.notification_id
    end
    transfer=R::Wallet.transfer(actor:@alice,recipient:@bob,amount:"1",request_id:SecureRandom.uuid)
    event=R::Event.find_by!(journal_id:transfer.journal.id);R::NotificationDelivery.deliver(event)
    assert_includes Notification.find(event.reload.notification_id).data_hash['river_text'],@alice.username
    assert_equal '<0.0001',R::Amount.display(1)
    assert_equal '1.2345',R::Amount.display(R::Amount.parse('1.23459999'))
  end

  def test_public_tip_batch_respects_post_visibility_without_requiring_wallet_membership
    fund
    category=Category.find_or_create_by!(name:'RSC public integration') { |c| c.user_id=@admin.id }
    category.set_permissions(everyone: :full);category.save!
    post=PostCreator.create!(@bob,title:'Synthetic public native RSC topic',raw:'Synthetic test text for the native tip integration.',category:category.id,skip_validations:true)
    result=R::Wallet.transfer(actor:@alice,recipient:@bob,post:post,amount:'1.23',request_id:SecureRandom.uuid)
    guest=ActionDispatch::Integration::Session.new(Rails.application);guest.host!('rsc.test');guest.https!
    guest.get "/rsc/topics/#{post.topic_id}/tips.json",params:{post_ids:post.id},headers:{'X-Requested-With'=>'XMLHttpRequest'}
    assert_equal 200,guest.response.status,guest.response.body
    data=JSON.parse(guest.response.body)['posts'][post.id.to_s];assert_equal '1.23',data['total'];assert_equal "/u/#{@alice.username}",data['tips'][0]['user_url']
    post.update!(hidden:true)
    guest.get "/rsc/topics/#{post.topic_id}/tips.json",params:{post_ids:post.id},headers:{'X-Requested-With'=>'XMLHttpRequest'}
    assert_equal 200,guest.response.status;assert_empty JSON.parse(guest.response.body)['posts']
    guest.get '/rsc/wallet.json';assert_includes [401,403],guest.response.status
  end

  def test_unified_history_paginates_without_duplicates_and_scopes_focus
    fund
    55.times do |n|
      R::LegacyRecord.create!(source_table:'ledger_entries',source_id:n.to_s,data:{'discourse_user_id'=>@alice.id,'created_at'=>(n+1).minutes.ago.iso8601,'type'=>'transfer','direction'=>'credit','amount_rsc'=>'0.123456789012345678','balance_after'=>'2','counterparty_discourse_user_id'=>@bob.id,'metadata'=>'{"reason":"legacy test","secret":"hidden"}'})
    end
    first=R::WalletHistory.page(@alice);assert_equal 50,first[:entries].size
    second=R::WalletHistory.page(@alice,cursor:first[:next_cursor]);assert_equal 6,second[:entries].size
    assert_equal 56,(first[:entries]+second[:entries]).map { |r| r[:id] }.uniq.size
    assert_nil second[:next_cursor];refute_includes first.to_json,'hidden'
    assert_empty R::WalletHistory.page(@bob)[:entries]
    recent=R::WalletHistory.page(@alice,per_page:20)
    assert_equal first[:entries].first(20),recent[:entries]
    following=R::WalletHistory.page(@alice,per_page:20,cursor:recent[:next_cursor])
    last=R::WalletHistory.page(@alice,per_page:20,cursor:following[:next_cursor])
    assert_equal [20,20,16],[recent,following,last].map { |page| page[:entries].size }
    assert_equal (first[:entries]+second[:entries]).map { |row| row[:id] },[recent,following,last].flat_map { |page| page[:entries].map { |row| row[:id] } }
    assert_nil last[:next_cursor]
    assert_code('invalid_page') { R::WalletHistory.page(@alice,per_page:10000) }
    R::Commands.move(user_id:nil,action:'legacy_opening',request_id:'history-opening-check',settlement:true,
      postings:{R::Account.wallet(@alice.id).id=>R::Amount.parse('1'),R::Account.issuance.id=>-R::Amount.parse('1')})
    before=[R::Journal.count,R::Account.wallet(@alice.id).reload.balance_units]
    refute_includes R::WalletHistory.page(@alice,per_page:20)[:entries].map { |row| row[:operation] },'legacy_opening'
    assert_equal before,[R::Journal.count,R::Account.wallet(@alice.id).reload.balance_units]
    assert_code('invalid_page') { R::WalletHistory.page(@alice,cursor:'bad cursor') }
    journal=R::Wallet.issue(actor:@admin,recipient:@bob,amount:'1',reason:'other account',request_id:SecureRandom.uuid).journal
    key=ApiKey.create!(user_id:@alice.id,created_by_id:@admin.id,description:'isolated focus privacy')
    session=ActionDispatch::Integration::Session.new(Rails.application);session.host!('rsc.test');session.https!
    headers={'Api-Key'=>key.key,'Api-Username'=>@alice.username}
    session.get '/rsc/history.json',params:{per_page:20},headers:headers
    assert_equal 200,session.response.status
    assert_equal 20,JSON.parse(session.response.body)['entries'].size
    session.get '/rsc/history.json',params:{journal_id:journal.id},headers:headers
    assert_equal 404,session.response.status
    own=R::Entry.where(account_id:R::Account.wallet(@alice.id).id).first
    session.get '/rsc/history.json',params:{journal_id:own.journal_id},headers:headers
    assert_equal 200,session.response.status,session.response.body
    assert_equal own.journal_id,JSON.parse(session.response.body)['focused_entry']['journal_id']
  ensure
    key&.destroy!
  end

  def test_old_pending_prediction_and_explicit_settled_match_remain_accessible
    fund;game=match
    result=R::Sports.predict(actor:@alice,match_id:game.id,pick:'home',stake:'1',request_id:SecureRandom.uuid)
    game.update!(starts_at:30.days.ago)
    205.times { |i| R::SportMatch.create!(external_id:SecureRandom.uuid,league:'Synthetic league',home:'Synthetic home',away:'Synthetic away',starts_at:(i+1).hours.from_now,status:'scheduled') }
    rows=R::Views.matches(@alice.id)
    assert_equal result['prediction_id'],rows.find { |r| r[:id]==game.id }[:prediction][:id]
    game.update!(status:'canceled');R::Sports.settle(game.id)
    refute R::Views.matches(@alice.id).any? { |r| r[:id]==game.id }
    assert_equal 'refunded',R::Views.matches(@alice.id,focus:game.id).find { |r| r[:id]==game.id }[:prediction][:status]
  end

  def test_legacy_search_requests_restore_idempotently_without_moving_assets
    fund
    2.times do |n|
      R::LegacyRecord.create!(source_table:'market_search_requests',source_id:n.to_s,data:{'discourse_user_id'=>@alice.id,'requested_symbol'=>'missing','requested_name'=>'Synthetic missing stock','created_at'=>(n+1).days.ago.iso8601})
    end
    R::LegacyRecord.create!(source_table:'outgoing_limit_exemptions',source_id:'1',data:{'discourse_user_id'=>@alice.id,'starts_at'=>1.day.from_now.iso8601,'expires_at'=>2.days.from_now.iso8601,'reason'=>'Future exemption'})
    stock=instrument
    old=R::Order.create!(user_id:@alice.id,instrument_id:stock.id,side:'close',status:'filled',quantity_units:R::Amount.parse('1'),leverage:1,details:{legacy_id:42})
    R::LegacyRecord.create!(source_table:'exchange_orders',source_id:'42',data:{'id'=>42,'discourse_user_id'=>@alice.id,'instrument_id'=>999,'side'=>'sell','status'=>'filled','order_type'=>'stop_loss','executed_price_rsc'=>'90','gross_rsc'=>'90','fee_rsc'=>'0.045'})
    counts=[R::Journal.count,R::Entry.count,R::Event.count,R::Account.wallet(@alice.id).balance]
    SiteSetting.rsc_read_only=true
    assert_equal 1,R::LegacyRules.restore![:requests]
    item=R::MarketRequest.first;assert_equal 'MISSING',item.symbol;assert_equal 'pending',item.status;assert_equal 2,item.details['request_count']
    assert_operator R::Exemption.first.starts_at,:>,Time.current
    assert_equal 'stock_stop_loss',old.reload.details['reason']
    assert_equal '90',old.details['gross']
    assert_equal 0,R::LegacyRules.restore![:requests]
    assert_equal counts,[R::Journal.count,R::Entry.count,R::Event.count,R::Account.wallet(@alice.id).balance]
  end

  def test_initial_protection_and_rejection_reason_are_preserved
    fund;stock=instrument;item=order(stock,take_profit:'120',stop_loss:'90')
    assert_equal 'filled',item.status
    assert_equal R::Amount.parse('120'),R::Position.first.take_profit_units
    assert_equal '100',item.details['gross']
    R::Exchange.submit(actor:@alice,instrument_id:stock.id,side:'close',quantity:'1',leverage:1,request_id:SecureRandom.uuid)
    stock.update!(category:'crypto');pending=order(stock)
    pending.update!(created_at:6.minutes.ago,execute_at:1.second.ago);stock.update!(quote:quote('110'));R::Exchange.process(stock.id)
    assert_equal 'rejected',pending.reload.status;assert_equal 'price_moved',pending.details['error']
    assert_equal 0,R::Entry.sum(:units)
  end
end

require "/rsc/test/access_review_test"

require "/rsc/test/completion_test"
require "/rsc/test/final_review_test"

require "/rsc/test/request_review_test"

require "/rsc/test/stream_test"
