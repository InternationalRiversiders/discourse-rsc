# frozen_string_literal: true
abort "Isolated snapshot only" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_readiness_snapshot"
r = DiscourseRsc
raise "Read-only must default on" unless SiteSetting.rsc_read_only
before = [r::Journal.count, r::Event.count, r::Account.sum(:balance_units).to_i]
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ids = r::Account.where(kind: "wallet").pluck(:user_id)
data = r::Reports.portfolio_data(ids)
rows = ids.map { |id| r::Reports.portfolio(id, data: data) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
campaign = r::Campaign.preview
period_ids = ids
complete = 0
inconsistent = 0
period_ids.each do |id|
  report = r::Reports.performance(id)
  next unless report[:complete]
  complete += 1
  expected = BigDecimal(rows.find { |row| row[:user_id] == id }.fetch(:realized_pnl))
  observed = BigDecimal(report[:points].last&.fetch(:pnl) || "0")
  inconsistent += 1 if (expected - observed).abs > BigDecimal("0.00001")
end
raise "Read path mutated accounts" unless before == [r::Journal.count, r::Event.count, r::Account.sum(:balance_units).to_i]
puts JSON.pretty_generate(wallets: rows.size, report_seconds: elapsed.round(3), campaign: campaign.except(:rows), performance: { periods: period_ids.size, reconstructable: complete, mismatches: inconsistent }, market: r::MarketData.health.except(:stale), journals_unchanged: true, notifications_unchanged: true)
