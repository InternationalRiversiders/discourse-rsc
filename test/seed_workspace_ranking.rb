# frozen_string_literal: true
abort 'Disposable only' unless ENV['RSC_DISPOSABLE_CONTAINER']=='1' && GlobalSetting.db_name=='rsc_discourse_smoke'
group=Group.find_by!(name:'rsc_test_members');admin=User.find_by!(username:'rsc_admin')
45.times do |n|
 user=User.find_or_create_by!(username:"workspace_#{n}") { |u| u.email="workspace_#{n}@example.invalid";u.password=SecureRandom.hex(24);u.active=true;u.approved=true;u.trust_level=1 }
 group.add(user)
 DiscourseRsc::Wallet.issue(actor:admin,recipient:user,amount:'1',reason:'Isolated pagination fixture',request_id:"workspace-ranking-#{n}")
end
Discourse.cache.delete("rsc:leaderboard:v3:equity:#{SiteSetting.rsc_allowed_groups}")
