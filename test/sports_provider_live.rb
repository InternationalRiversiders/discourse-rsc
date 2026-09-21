# Read-only public source check; no forum database, credentials or money jobs.
abort 'Set RSC_PUBLIC_PROVIDER_PROBE=1' unless ENV['RSC_PUBLIC_PROVIDER_PROBE'] == '1'
require 'active_support/all'
require 'redis'
module Discourse
  def self.redis; @redis ||= Redis.new(url: ENV.fetch('RSC_PROBE_REDIS_URL')); end
end
require 'json'
require 'bigdecimal'
module DiscourseRsc; end
require '/rsc/lib/discourse_rsc/error'
require '/rsc/app/services/discourse_rsc/provider_http'
require '/rsc/app/services/discourse_rsc/sports_data'

queue = Queue.new
DiscourseRsc::SportsData::LEAGUES.each do |sport, leagues|
  leagues.each { |league| DiscourseRsc::SportsData.date_buckets.each { |dates| queue << [sport, league, dates] } }
end
results = []; fixtures = []; lock = Mutex.new
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Array.new(4) do
  Thread.new do
    loop do
      pair = queue.pop(true) rescue nil
      break unless pair
      sport, league, dates = pair
      begin
        data = DiscourseRsc::ProviderHttp.get('site.api.espn.com', "/apis/site/v2/sports/#{sport}/#{league}/scoreboard", dates: dates, limit: 500)
        events = data.fetch('events')
        raise 'Invalid events' unless events.is_a?(Array)
        events.each do |event|
          DateTime.iso8601(event.fetch('date'))
          event.fetch('competitions').first.fetch('competitors')
        end
        lock.synchronize { fixtures << {sport: sport, league: league, dates: dates, response: data} }
        result = {source: "#{sport}:#{league}", dates: dates, ok: true, events: events.size}
      rescue StandardError => error
        result = {source: "#{sport}:#{league}", ok: false, error: error.is_a?(DiscourseRsc::Error) ? error.code : error.class.name}
      end
      lock.synchronize { results << result }
    end
  end
end.each(&:value)
puts JSON.generate(seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2), sources: results.size, successful: results.count { |r| r[:ok] }, results: results.sort_by { |r| r[:source] })
if ENV['RSC_SPORTS_FIXTURES']
  File.open(ENV.fetch('RSC_SPORTS_FIXTURES'), 'w', 0o600) { |file| file.write(JSON.generate(fixtures)) }
end
exit(results.all? { |r| r[:ok] } ? 0 : 1)
