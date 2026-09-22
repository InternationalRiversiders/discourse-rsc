# frozen_string_literal: true
abort 'Disposable only' unless ENV['RSC_DISPOSABLE_CONTAINER']=='1' && GlobalSetting.db_name=='rsc_discourse_smoke'
r=DiscourseRsc
user=User.find_by!(username:'rsc_alice')
SiteSetting.default_theme_id=-2
SiteSetting.navigation_menu='sidebar'
SiteSetting.rsc_crypto_stream_enabled=false
SiteSetting.rsc_high_risk_enabled=true
SiteSetting.rsc_daily_rewards_enabled=false
UserOption.update_all(color_scheme_id:1,dark_scheme_id:2)
r::Instrument.find_each do |i|
 i.update!(quote:i.quote.merge('open'=>'100','high'=>'300','low'=>'90','change_basis'=> i.category=='crypto' ? '24h' : 'previous_close'))
end
stock=r::Instrument.find_by!(symbol:'DEMO-A')
# More than one page, without any calls to external providers.
35.times do |n|
 r::Instrument.create!(symbol:"PAGE-#{n.to_s.rjust(2,'0')}",name:"分页演示 #{n+1}",category:'us',quote:stock.quote,history:stock.history)
end
r::Instrument.find_by!(symbol:'DEMO-C').update!(minimum_units:r::Amount.parse('0.001'),step_units:r::Amount.parse('0.001'))
['DEMO-A','DEMO-C'].each do |symbol|
 i=r::Instrument.find_by!(symbol:symbol)
 result=r::Exchange.submit(actor:user,instrument_id:i.id,side:'long',quantity:'2',leverage:i.category=='crypto' ? 20 : 2,high_risk:i.category=='crypto',request_id:SecureRandom.uuid)
 order=r::Order.find(result['order_id'])
 if order.status=='pending'
  order.update!(created_at:10.minutes.ago,execute_at:1.second.ago)
  i.update!(quote:i.quote.merge('source_time'=>Time.current.iso8601(6),'received_at'=>Time.current.iso8601(6)))
  r::Exchange.process(i.id)
 end
 raise 'Unfilled seed' unless order.reload.status=='filled'
end
# A real partial close leaves an occupied high-risk position and a cooldown.
i=r::Instrument.find_by!(symbol:'DEMO-C')
r::Position.find_by!(user_id:user.id,instrument_id:i.id).update!(hold_until:1.minute.ago)
result=r::Exchange.submit(actor:user,instrument_id:i.id,side:'close',quantity:'0.5',leverage:20,request_id:SecureRandom.uuid)
order=r::Order.find(result['order_id']);order.update!(created_at:10.minutes.ago,execute_at:1.second.ago)
i.update!(quote:i.quote.merge('source_time'=>Time.current.iso8601(6),'received_at'=>Time.current.iso8601(6)))
r::Exchange.process(i.id)
raise 'Unfilled seed close' unless order.reload.status=='filled'
r::Instrument.create!(symbol:'DEMO-OTHER-COIN',name:'另一种数字资产',category:'crypto',quote:i.quote,history:i.history,minimum_units:r::Amount.parse('0.001'),step_units:r::Amount.parse('0.001'))
