abort 'isolated only' unless ENV['RSC_DISPOSABLE_CONTAINER']=='1' && GlobalSetting.db_name=='rsc_discourse_smoke'
SiteSetting.default_theme_id=-2
SiteSetting.navigation_menu='sidebar'
SiteSetting.rsc_daily_rewards_enabled=false
SiteSetting.rsc_crypto_stream_enabled=false
r=DiscourseRsc
user=User.find_by!(username:'rsc_alice')
35.times do |n|
 r::LegacyRecord.create!(source_table:'ledger_entries',source_id:"compact-#{n}",data:{'discourse_user_id'=>user.id,'created_at'=>(n+60).minutes.ago.iso8601,'type'=>'transfer','direction'=>n.even? ? 'credit' : 'debit','amount_rsc'=>'0.123456789012345678','balance_after'=>'1000.25','counterparty_username'=>'rsc_bob','metadata'=>{}})
end
r::Commands.move(user_id:nil,action:'legacy_opening',request_id:'compact-opening-fixture',settlement:true,postings:{r::Account.wallet(user.id).id=>r::Amount.parse('1'),r::Account.issuance.id=>-r::Amount.parse('1')})
stock=r::Instrument.find_by!(symbol:'DEMO-C')
[['close','0.1579','legacy_import'],['close','-12.5','manual_close'],['close','0','manual_close'],['long','0','legacy_import']].each do |side,pnl,reason|
 r::Order.create!(user_id:user.id,instrument_id:stock.id,side:side,leverage:1,status:'filled',quantity_units:r::Amount.parse('0.011'),details:{'price'=>'1857.8124','fee'=>'0.0204','pnl'=>pnl,'gross'=>'20.4359','reason'=>reason})
end
r::Position.create!(user_id:user.id,instrument_id:stock.id,side:'long',quantity_units:r::Amount.parse('0.04323'),average_units:r::Amount.parse('240.8'),margin_units:r::Amount.parse('3'),leverage:5)
UserOption.update_all(color_scheme_id:1,dark_scheme_id:2)
