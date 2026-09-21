abort 'isolated only' unless ENV['RSC_DISPOSABLE_CONTAINER']=='1' && GlobalSetting.db_name=='rsc_discourse_smoke'
R=DiscourseRsc
case ARGV.fetch(0)
when 'prepare'
  require 'sidekiq/api'
  Sidekiq::Queue.all.each(&:clear)
  SiteSetting.rsc_enabled=true;SiteSetting.rsc_native_trial_enabled=true;SiteSetting.rsc_read_only=false
  SiteSetting.rsc_notifications_enabled=true;SiteSetting.rsc_market_data_enabled=false;SiteSetting.rsc_sports_data_enabled=false;SiteSetting.rsc_daily_rewards_enabled=false
  alice=User.find_by!(username:'rsc_alice');bob=User.find_by!(username:'rsc_bob')
  packet=R::RedPackets.create(actor:alice,mode:'fixed',count:2,amount:'1',request_id:SecureRandom.uuid)
  R::Packet.find_by!(token:packet['token']).update!(expires_at:1.minute.ago)
  transfer=R::Wallet.transfer(actor:alice,recipient:bob,amount:'3.25',request_id:SecureRandom.uuid)
  game=R::SportMatch.create!(external_id:'sidekiq-probe',league:'Trial',home:'Home',away:'Away',starts_at:1.day.from_now,odds_at:Time.current,odds:{home:'2',away:'3'})
  prediction=R::Sports.predict(actor:alice,match_id:game.id,pick:'home',stake:'10',request_id:SecureRandom.uuid)
  game.update!(status:'finished',result:'home',confirmed_at:6.minutes.ago)
  stock=R::Instrument.create!(symbol:'SIDEKIQ-PROBE',name:'Probe',category:'us',provider:'manual',quote:{price:'100',source_time:Time.current.iso8601,received_at:Time.current.iso8601,session_start:1.hour.ago.iso8601,session_end:1.day.from_now.iso8601})
  R::Exchange.submit(actor:alice,instrument_id:stock.id,side:'long',quantity:'1',leverage:5,request_id:SecureRandom.uuid)
  stock.update!(quote:stock.quote.merge('price'=>'70'))
  File.write('/tmp/sidekiq-probe.json',{packet:packet['token'],event:R::Event.find_by!(journal_id:transfer.journal.id).id,prediction:prediction['prediction_id'],instrument:stock.id}.to_json)
  puts JSON.generate(prepared:true,queued:Sidekiq::Queue.all.sum(&:size))
when 'requeue'
  ids=JSON.parse(File.read('/tmp/sidekiq-probe.json'))
  baseline=[R::Journal.count,R::Entry.count,Notification.count,R::Account.order(:id).pluck(:balance_units).map(&:to_s)]
  File.write('/tmp/sidekiq-baseline.json',baseline.to_json)
  3.times { Jobs.enqueue(:discourse_rsc_notify,event_id:ids['event']) }
  puts JSON.generate(queued_replays:3)
when 'verify', 'verify_restart'
  ids=JSON.parse(File.read('/tmp/sidekiq-probe.json'))
  packet=R::Packet.find_by!(token:ids['packet']);event=R::Event.find(ids['event']);prediction=R::Prediction.find(ids['prediction'])
  liquidation=R::Event.where(kind:'stock_liquidated').find_by("payload->>'instrument_id' = ?",ids['instrument'].to_s)
  relevant=R::Event.where(id:ids['event']).or(R::Event.where("payload->>'packet_token' = ?",ids['packet'])).or(R::Event.where("payload->>'prediction_id' = ?",ids['prediction'].to_s)).or(R::Event.where("payload->>'instrument_id' = ?",ids['instrument'].to_s))
  passed=packet.status=='expired' && prediction.status=='won' && liquidation && event.delivered_at && relevant.where(delivered_at:nil).empty? && !R::Position.exists?(instrument_id:ids['instrument'])
  raise 'not finished' unless passed
  relevant.each do |e|
    raise 'duplicate or missing notification' unless Notification.where("data::jsonb->>'rsc_journal_id' = ?",e.journal_id.to_s).where(user_id:e.recipient_user_id).count==1
  end
  raise 'unbalanced ledger' unless R::Entry.sum(:units).zero?
  if ARGV.first=='verify_restart'
    baseline=JSON.parse(File.read('/tmp/sidekiq-baseline.json'))
    raise 'restart replay changed money or notifications' unless baseline==[R::Journal.count,R::Entry.count,Notification.count,R::Account.order(:id).pluck(:balance_units).map(&:to_s)]
    raise 'queued replays were not consumed' unless Sidekiq::Queue.new('default').size.zero?
  end
  puts JSON.generate(passed:true,notifications:relevant.count,packet_expiry:true,prediction_settled:true,liquidation:true)
end
