# frozen_string_literal: true
# Read-only comparison with the old backend's output for the SAME SQLite snapshot.
abort "Private read-only snapshot required" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_readiness_snapshot" && SiteSetting.rsc_read_only
%w[valuation market_listing reports].each { |file| load "/rsc/app/services/discourse_rsc/#{file}.rb" }
r = DiscourseRsc
require "digest"
fingerprint = -> { Digest::SHA256.hexdigest([r::Account.order(:id).pluck(:id, :balance_units), r::Journal.count, r::Entry.count, r::Event.count].to_json) }
before = fingerprint.call
reference = JSON.parse(File.read(ENV.fetch("RSC_PARITY_REFERENCE")))
fields = { equity: "totalEquityRsc", portfolio_equity: "portfolioEquityRsc", realized_pnl: "realizedPnlRsc", pnl: "unrealizedPnlRsc", total_pnl: "totalPnlRsc", return_pct: "returnPct", trade_count: "tradeCount" }
checked = 0
fields.each_key do |sort|
  Discourse.cache.delete("rsc:leaderboard:v3:#{sort}:#{SiteSetting.rsc_allowed_groups}")
  actual = r::Reports.leaderboard(sort.to_s)
  expected_count = reference.fetch(sort.to_s).fetch("pagination").fetch("total") - (sort == :equity ? 1 : 0) # unresolved orphan is excluded from this preview
  raise "#{sort} participant count #{actual.size} != #{expected_count}" unless actual.size == expected_count
  expected = reference.fetch(sort.to_s).fetch("leaderboard")
  expected.each_with_index do |old, index|
    row = actual.fetch(index)
    raise "#{sort} rank #{index + 1}: expected #{old['username']}, got #{row[:username]}" unless row[:user_id] == old.fetch("discourseUserId")
    fields.each do |key, legacy_key|
      raise "#{sort} rank #{index + 1} #{key}: #{row[key]} != #{old[legacy_key]}" unless BigDecimal(row.fetch(key).to_s) == BigDecimal(old.fetch(legacy_key).to_s)
    end
    checked += 1
  end
  puts "PASS #{sort}: #{expected.size} ranks and 7 metrics"
end
markets = r::MarketListing.rows(r::Instrument.where(active: true))
expected = reference.fetch("markets").map { |row| row.fetch("symbol") }
unless markets.map { |row| row[:symbol] } == expected
  index = (0...[markets.size, expected.size].min).find { |i| markets[i][:symbol] != expected[i] }
  raise "Market order mismatch at #{index}: #{markets[index].slice(:symbol, :popularity, :last_order_at, :catalog_rank, :catalog_id)} expected #{reference['markets'][index]} (sizes #{markets.size}/#{expected.size})"
end
raise "Financial data changed" unless before == fingerprint.call
puts "PASS #{markets.size} market positions; #{checked} ranked rows; accounting fingerprint unchanged"
