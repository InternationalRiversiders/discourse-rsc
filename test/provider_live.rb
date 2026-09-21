# Manual read-only public-provider probe. No database, sessions, secrets or jobs.
abort 'Set RSC_PUBLIC_PROVIDER_PROBE=1' unless ENV['RSC_PUBLIC_PROVIDER_PROBE']=='1'
require 'active_support/all'
require 'redis'
module Discourse
  def self.redis; @redis ||= Redis.new(url: ENV.fetch('RSC_PROBE_REDIS_URL')); end
end
require 'ostruct'
require 'json'
require 'bigdecimal'
require 'erb'
module DiscourseRsc; end
require '/rsc/lib/discourse_rsc/error'
require '/rsc/lib/discourse_rsc/amount'
require '/rsc/app/services/discourse_rsc/provider_http'
require '/rsc/app/services/discourse_rsc/catalog'
require '/rsc/app/services/discourse_rsc/market_data'
module Discourse
  def self.cache; @cache ||= ActiveSupport::Cache::MemoryStore.new; end
end
rows=JSON.parse(File.read(ARGV.fetch(0)))
previous={}
cycles=Integer(ENV.fetch('RSC_PROBE_CYCLES','2'))
cycles.times do |cycle|
  queue=Queue.new;rows.each { |r| queue<<r }
  started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
  results=[];lock=Mutex.new
  Array.new(4) do
    Thread.new do
      loop do
        row=queue.pop(true) rescue nil
        break unless row
        provider,code=DiscourseRsc::Catalog.provider(row)
        begin
          quote=DiscourseRsc::MarketData.fetch_quote(OpenStruct.new(symbol:row['symbol'],provider:provider,provider_symbol:code,currency:row['currency']))
          quote=DiscourseRsc::MarketData.observe_delay(previous.fetch(row['symbol'],{}),quote,category:row['market_category'])
          previous[row['symbol']]=quote
          session_end=quote['session_end'] && Time.iso8601(quote['session_end'])
          session_start=quote['session_start'] && Time.iso8601(quote['session_start'])
          result={symbol:row['symbol'],provider:provider,ok:true,source_age:(Time.current-Time.iso8601(quote.fetch('source_time'))).round,
            delay:quote['delay_seconds'],inferred:quote['delay_inferred'],session_open:row['market_category']=='crypto' || (session_start && session_end && session_start<=Time.current && session_end>Time.current)}
        rescue => error
          result={symbol:row['symbol'],provider:provider,ok:false,error:error.is_a?(DiscourseRsc::Error) ? error.code : error.class.name}
        end
        lock.synchronize { results<<result }
      end
    end
  end.each(&:value)
  puts JSON.generate(cycle:cycle+1,seconds:(Process.clock_gettime(Process::CLOCK_MONOTONIC)-started).round(2),count:results.size,ok:results.count { |r| r[:ok] },results:results)
  $stdout.flush
  sleep(Integer(ENV.fetch('RSC_PROBE_PAUSE','0'))) if cycle+1<cycles
end
