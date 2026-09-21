# frozen_string_literal: true
abort "Private read-only snapshot required" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_readiness_snapshot" && SiteSetting.rsc_read_only
r = DiscourseRsc
before = [r::Account.order(:id).pluck(:id, :balance_units), r::Journal.count, r::Entry.count, r::Event.count]
ids = r::LegacyRecord.where(source_table: "users").where("data ->> 'is_verified' = '1'").pluck(Arel.sql("data ->> 'discourse_user_id'")).map(&:to_i)
raise "Unexpected real forum identities" if UserEmail.where(user_id: ids).where.not("email LIKE '%@rsc-rehearsal.invalid'").exists?
group = Group.find_by!(name: "rsc_private_preview")
User.where(id: ids).update_all(active: true, approved: true)
GroupUser.insert_all(ids.map { |id| { user_id: id, group_id: group.id, owner: false } }, unique_by: %i[group_id user_id])
load "/rsc/app/services/discourse_rsc/legacy_market.rb"
puts "Historical display restored: #{r::LegacyMarket.restore!}; verified stub members: #{ids.size}"
raise "Accounting changed" unless before == [r::Account.order(:id).pluck(:id, :balance_units), r::Journal.count, r::Entry.count, r::Event.count]
puts "Accounting and notifications unchanged"
