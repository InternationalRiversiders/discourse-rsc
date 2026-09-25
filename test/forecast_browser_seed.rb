# frozen_string_literal: true
abort 'Disposable only' unless ENV['RIVER_DISPOSABLE']=='1' && GlobalSetting.db_name=='river_community_test'
require 'securerandom'
SiteSetting.rsc_enabled=true
SiteSetting.rsc_native_trial_enabled=true
SiteSetting.rsc_forecast_enabled=true
SiteSetting.rsc_read_only=false
SiteSetting.rsc_notifications_enabled=false
SiteSetting.rsc_market_data_enabled=false
SiteSetting.rsc_sports_data_enabled=false
SiteSetting.force_https=false
SiteSetting.port=3000
SiteSetting.external_system_avatars_enabled=false
SiteSetting.default_locale='zh_CN'
SiteSetting.title='RS Coin · 预测市场隔离测试'
SiteSetting.must_approve_users=false
SiteSetting.login_required=false
member=Group.find_or_create_by!(name:'forecast_members')
SiteSetting.rsc_allowed_groups=member.id.to_s
users={}
%w[alice admin].each do |role|
 name="forecast_#{role}"
 u=User.find_by(username:name) || User.new(username:name,email:"#{name}@example.com")
 password=SecureRandom.hex(24)
 u.assign_attributes(password:password,locale:'zh_CN',active:true,approved:true,trust_level:2,admin:role=='admin')
 u.save!;u.activate;member.add(u)
 users[role]={username:name,password:password}
 DiscourseRsc::Wallet.issue(actor:User.find_by!(username:'forecast_admin'),recipient:u,amount:'1000',reason:'Disposable browser seed',request_id:SecureRandom.uuid)
end
raws=JSON.parse(File.read('/community/results/forecast-20260925/public-markets.json'))
DiscourseRsc::ForecastMarket.update_all(featured:false)
raws.each { |raw| DiscourseRsc::ForecastProvider.ingest(raw,featured:true) }
# One explicit synthetic question for deterministic real HTTP buy/sell tests.
raw={ 'id'=>'999999999', 'conditionId'=>'0x'+'f'*64,'question'=>'测试：今年的校园音乐节会在周末举办吗？',
 'events'=>[{'title'=>'校园音乐节 · 仅供测试'}],'slug'=>'rsc-isolated-demo','description'=>"这是隔离环境的演示问题，资金与生产环境无关。\n若最终结果为是，则是份额每份兑付 1 RSC，否则否份额兑付 1 RSC。",'endDate'=>7.days.from_now.iso8601,
 'outcomes'=>'["Yes","No"]','clobTokenIds'=>'["999123","999456"]','outcomePrices'=>'["0.60","0.40"]',
 'active'=>true,'closed'=>false,'acceptingOrders'=>true,'enableOrderBook'=>true,'liquidity'=>'10000','volume24hr'=>'999999999' }
# If already present, retain its original terms so the seed stays safe to rerun.
existing=DiscourseRsc::ForecastMarket.find_by(external_id:raw['id'])
raw['endDate']=existing.ends_at.iso8601 if existing
market=DiscourseRsc::ForecastProvider.ingest(raw,featured:true)
File.write('/tmp/forecast-browser-data.json',raws.push(raw).to_json,perm:0o600)
users['market_id']=market.id
File.write('/tmp/forecast-browser-credentials.json',users.to_json,perm:0o600)
puts "Seeded #{raws.size} public/synthetic questions; isolated credentials saved."
