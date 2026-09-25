abort 'Disposable only' unless ENV['RIVER_DISPOSABLE']=='1' && ENV['DISCOURSE_DB_NAME']=='river_community_test'
ENV['DISCOURSE_RUNNING_IN_RACK']='1'
require '/var/www/discourse/config/environment'
MessageBus.long_polling_enabled=false
RateLimiter.disable
# External provider responses are synthetic in this network-isolated browser test.
# All forum routes, CSRF, balances, positions and ledger writes are real.
module DiscourseRsc::ForecastProvider
  def self.get(host,path,query={})
    rows=JSON.parse(File.read('/tmp/forecast-browser-data.json'))
    if host==GAMMA
      path=='/markets' ? rows : rows.find { |r| r['id']==path.split('/').last }
    elsif host==DATA
      { 'data'=>[] }
    elsif host==CLOB && path=='/book'
      raw=rows.find { |r| JSON.parse(r['clobTokenIds']).include?(query[:token_id]) }
      index=JSON.parse(raw['clobTokenIds']).index(query[:token_id])
      price=BigDecimal(JSON.parse(raw['outcomePrices'])[index])
      { 'market'=>raw['conditionId'],'asset_id'=>query[:token_id],'timestamp'=>(Time.current.to_f*1000).to_i.to_s,
        'bids'=>[{'price'=>(price-BigDecimal('0.01')).to_s('F'),'size'=>'10000'}],
        'asks'=>[{'price'=>price.to_s('F'),'size'=>'10000'}] }
    elsif host==CLOB && path=='/prices-history'
      days={'1d'=>1,'1w'=>7,'1m'=>30,'max'=>60}.fetch(query[:interval],7)
      { 'history'=>60.times.map { |i| {'t'=>Time.current.to_i-days*86400+i*days*86400/59,'p'=>(0.48 + 0.002*i + Math.sin(i/5.0)*0.045).round(4).to_s} } }
    else
      raise 'Unexpected external request in disposable server'
    end
  end
end
use Rack::Static,urls:['/assets','/images','/fonts','/uploads'],root:'/var/www/discourse/public'
run Discourse::Application
