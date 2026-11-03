# frozen_string_literal: true
abort 'Disposable only' unless ENV['RSC_DISPOSABLE_CONTAINER']=='1' && GlobalSetting.db_name=='rsc_discourse_smoke'
load '/rsc/test/seed_browser.rb'
r=DiscourseRsc
alice=User.find_by!(username:'rsc_alice')
item=r::Instrument.find_by!(symbol:'DEMO-A')
r::Exchange.submit(actor:alice,instrument_id:item.id,side:'long',quantity:'1',leverage:5,request_id:SecureRandom.uuid)
item.update!(quote:item.quote.merge('source_time'=>1.hour.ago.iso8601,'received_at'=>1.hour.ago.iso8601))
pending=r::Instrument.find_by!(symbol:'DEMO-B')
pending.update!(quote:pending.quote.merge('delay_seconds'=>900,'source_time'=>15.minutes.ago.iso8601))
r::Exchange.submit(actor:alice,instrument_id:pending.id,side:'long',quantity:'1',leverage:1,request_id:SecureRandom.uuid)
closed=r::Instrument.find_by!(symbol:'DEMO-D')
closed.update!(quote:closed.quote.merge('session_end'=>1.minute.ago.iso8601))
File.write('/tmp/rsc-reliability-ids.json',{pending:pending.id,closed:closed.id}.to_json)
