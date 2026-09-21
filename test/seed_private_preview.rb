# frozen_string_literal: true
abort "Private isolated snapshot only" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_readiness_snapshot"
r = DiscourseRsc
before = [r::Journal.count, r::Event.count, r::Entry.sum(:units).to_i, r::Account.sum(:balance_units).to_i]
SiteSetting.rsc_enabled = true
SiteSetting.rsc_native_trial_enabled = true
SiteSetting.rsc_read_only = true
SiteSetting.rsc_notifications_enabled = false
SiteSetting.rsc_daily_rewards_enabled = false
SiteSetting.rsc_campaign_enabled = false
SiteSetting.rsc_market_data_enabled = false
SiteSetting.rsc_sports_data_enabled = false
SiteSetting.force_https = false
SiteSetting.port = 13000
SiteSetting.external_system_avatars_enabled = false
SiteSetting.login_required = true
SiteSetting.allow_new_registrations = false
SiteSetting.default_locale = "zh_CN"
SiteSetting.title = "RSC 真实快照 · 只读预览"
SiteSetting.must_approve_users = true
group = Group.find_or_create_by!(name: "rsc_private_preview")
SiteSetting.rsc_allowed_groups = group.id.to_s
# These are isolated, synthetic forum identities created by the import rehearsal,
# with invalid email addresses and random passwords. No production auth is copied.
ids = r::Account.where(kind: "wallet").pluck(:user_id) | r::LegacyRecord.where(source_table: "users").pluck(Arel.sql("data ->> 'discourse_user_id'")).map(&:to_i)
raise "Unexpected real forum identities" if UserEmail.where(user_id: ids).where.not("email LIKE '%@rsc-rehearsal.invalid'").exists?
User.where(id: ids).update_all(active: true, approved: true)
GroupUser.insert_all(ids.map { |id| { user_id: id, group_id: group.id, owner: false } }, unique_by: %i[group_id user_id])
password = SecureRandom.hex(24)
admin = User.find_by(username: "rsc_preview_admin") || User.new(username: "rsc_preview_admin", email: "rsc_preview_admin@rsc-rehearsal.invalid")
admin.assign_attributes(password: password, active: true, approved: true, admin: true, locale: "zh_CN")
admin.save!
admin.activate
group.add(admin)
raise "Read-only seeding changed accounting" unless before == [r::Journal.count, r::Event.count, r::Entry.sum(:units).to_i, r::Account.sum(:balance_units).to_i]
File.write("/tmp/rsc-private-key.json", { username: admin.username, password: password, url: "http://127.0.0.1:13000/rsc/market", read_only: true }.to_json, mode: "w", perm: 0600)
puts "Private read-only preview configured; accounting unchanged."
