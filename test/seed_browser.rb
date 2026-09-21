# frozen_string_literal: true
abort "Isolated test only" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_discourse_smoke"
R = DiscourseRsc
# Journal IDs are reset below; remove notifications from the previous synthetic run.
Notification.where("data::jsonb ->> 'rsc' = 'true'").destroy_all
ActiveRecord::Base.connection.execute("TRUNCATE discourse_rsc_events, discourse_rsc_entries, discourse_rsc_journals, discourse_rsc_accounts, discourse_rsc_commands, discourse_rsc_instruments, discourse_rsc_sport_matches, discourse_rsc_packets RESTART IDENTITY CASCADE")
ActiveRecord::Base.connection.execute("TRUNCATE discourse_rsc_audits, discourse_rsc_exemptions, discourse_rsc_legacy_records, discourse_rsc_market_requests, discourse_rsc_history_caches RESTART IDENTITY CASCADE")
SiteSetting.rsc_market_data_enabled = ENV['RSC_BROWSER_REFRESH_QUOTES'] == '1'
SiteSetting.rsc_sports_data_enabled = false
SiteSetting.rsc_high_risk_enabled = false
SiteSetting.rsc_read_only = false
    SiteSetting.rsc_enabled = true
SiteSetting.rsc_native_trial_enabled = true
SiteSetting.force_https = false
SiteSetting.port = 3000
SiteSetting.external_system_avatars_enabled = false
SiteSetting.login_required = false
SiteSetting.default_locale = "zh_CN"
SiteSetting.title = "RSC 原生试用"
SiteSetting.must_approve_users = false
SiteSetting.rsc_daily_outgoing_amount = "300"
group = Group.find_or_create_by!(name: "rsc_test_members")
SiteSetting.rsc_allowed_groups = group.id.to_s
admin = User.find_by!(username: "rsc_admin")
alice = User.find_by!(username: "rsc_alice")
bob = User.find_by!(username: "rsc_bob")
[alice, bob, admin].each { |user| group.add(user); user.update!(locale: "zh_CN", trust_level: 2); R::Account.wallet(user.id).update!(status: "active") }
[alice, bob].each do |user|
  R::Wallet.issue(actor: admin, recipient: user.reload, amount: "10000", reason: "browser trial", request_id: SecureRandom.uuid)
end
now = Time.current
[
  ["DEMO-A", "河畔科技", "128.50", "us", "125.10"],
  ["DEMO-B", "河畔指数", "96.20", "us", "97.60"],
  ["DEMO-C", "数字资产", "240.80", "crypto", "232.50"],
  ["DEMO-D", "远山能源", "43.75", "us", "44.80"],
  ["DEMO-E", "星海半导体", "186.30", "us", "178.50"],
  ["DEMO-F", "清源医药", "62.10", "hk", "62.10"],
  ["DEMO-G", "北岸消费", "35.60", "hk", "36.40"],
  ["DEMO-H", "云端计算", "214.90", "us", "210.00"],
  ["DEMO-I", "河畔制造", "58.25", "cn", "57.30"],
  ["DEMO-J", "数字指数", "105.20", "crypto", "103.10"],
  ["DEMO-K", "新港物流", "78.60", "hk", "79.90"],
  ["DEMO-L", "报价待更新", "12.50", "cn", nil],
].each_with_index do |(symbol, name, price, category, previous_close), index|
  instrument = R::Instrument.find_or_initialize_by(symbol: symbol)
  history = 60.times.map { |i| { price: (BigDecimal(price) + BigDecimal(Math.sin(i / 5.0).to_s) * 2 + (BigDecimal(previous_close || price) - BigDecimal(price)) * (59 - i) / 59).round(2).to_s("F"), at: (now - (60 - i).minutes).iso8601 } }
  instrument.assign_attributes(name: name, category: category, history: history,
    quote: { "price" => price, "previous_close" => previous_close, "local_price" => (%w[us crypto].include?(category) ? price : nil), "local_currency" => (%w[us crypto].include?(category) ? "USD" : nil), "source_time" => (symbol == "DEMO-L" ? now - 600 : now).iso8601(6), "received_at" => (symbol == "DEMO-L" ? now - 600 : now).iso8601(6), "delay_seconds" => 0,
             "session_start" => 1.hour.ago.iso8601, "session_end" => 1.day.from_now.iso8601, "demo" => true, "demo_stale" => symbol == "DEMO-L" })
  instrument.save!
end
[
  ["trial-soccer", "足球 · 演示联赛", "河畔联队", "山城竞技", true],
  ["trial-basketball", "篮球 · 演示联赛", "蓝鲸", "飞鸟", false],
].each do |id, league, home, away, draw|
  game = R::SportMatch.find_or_initialize_by(external_id: id)
  game.update!(league: league, home: home, away: away, sport: draw ? "soccer" : "basketball", allow_draw: draw, starts_at: 1.day.from_now,
               odds_at: now, status: "scheduled", odds: { "home" => "1.85", "away" => "2.20" }.merge(draw ? { "draw" => "3.10" } : {}), source: "demo")
end
category = Category.find_or_create_by!(name: "RSC public test") { |item| item.user_id = admin.id }
category.set_permissions(everyone: :full)
category.save!
SiteSetting.create_topic_allowed_groups = group.id.to_s
post = Post.joins(:topic).find_by(user_id: bob.id, topics: { title: "欢迎体验原生 RSC 社区经济" })
post ||= PostCreator.create!(bob.reload, category: category.id, title: "欢迎体验原生 RSC 社区经济", raw: "这是原生插件的隔离演示话题。可以在帖子下方打赏，并在论坛通知中查看到账消息。")
R::Wallet.transfer(actor: bob.reload, recipient: alice.reload, amount: "2.50", request_id: SecureRandom.uuid)
R::Event.find_each { |event| R::NotificationDelivery.deliver(event) }
password = SecureRandom.hex(24)
alice.activate
alice.password = password
alice.save!
admin.activate
admin_password = SecureRandom.hex(24)
admin.password = admin_password
admin.save!
File.write("/tmp/rsc-browser-key.json", { admin: { username: admin.username, password: admin_password }, username: alice.username, password: password, topic_path: "/t/#{post.topic_id}" }.to_json)
