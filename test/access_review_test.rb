# frozen_string_literal: true
class AccessReviewTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def request_as(user, path)
    key = ApiKey.create!(user_id: user.id, created_by_id: @admin.id, description: "isolated permission regression")
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host!("rsc.test")
    session.https!
    session.get path, headers: { "Api-Key" => key.key, "Api-Username" => user.username }
    [session.response.status, JSON.parse(session.response.body)]
  ensure
    key&.destroy!
  end

  def test_admin_only_and_member_permissions_are_independent
    @group.remove(@admin)
    refute R::Access.member?(@admin.reload)
    assert R::Access.admin?(@admin)
    assert_equal 200, request_as(@admin, "/rsc/admin/state.json").first
    status, body = request_as(@admin, "/rsc/state.json")
    assert_equal 403, status
    assert_equal "membership_required", body["error_code"]
    @group.add(@admin)
    assert_equal 200, request_as(@admin, "/rsc/state.json").first
    assert_equal 200, request_as(@admin, "/rsc/admin/state.json").first
  ensure
    @group.remove(@admin)
  end

  def test_revoked_membership_does_not_keep_wallet_access
    assert_equal 200, request_as(@alice, "/rsc/state.json").first
    @group.remove(@alice)
    assert_equal 403, request_as(@alice, "/rsc/state.json").first
    assert_equal 403, request_as(@alice, "/rsc/admin/state.json").first
  end

  def test_suspended_and_inactive_admins_have_no_privilege_bypass
    @admin.update!(suspended_till: 1.day.from_now)
    refute R::Access.admin?(@admin.reload)
    @admin.update!(suspended_till: nil, active: false)
    refute R::Access.admin?(@admin.reload)
  ensure
    @admin.update!(suspended_till: nil, active: true)
  end

  def test_reward_preview_is_read_only_for_members_without_wallets
    date = ((Time.current.utc + 8.hours).to_date - 1).iso8601
    UserVisit.find_or_create_by!(user_id: @alice.id, visited_at: date)
    refute R::Account.exists?(user_id: @alice.id, kind: "wallet")
    SiteSetting.rsc_read_only = true
    counts = [R::Account.count, R::Journal.count, R::Command.count]
    row = R::Rewards.preview(date).find { |item| item[:user_id] == @alice.id }
    assert row
    assert_equal 1, row[:score]
    assert_equal false, row[:paid]
    assert_equal counts, [R::Account.count, R::Journal.count, R::Command.count]
  ensure
    SiteSetting.rsc_read_only = false
  end

  def test_empty_wallet_can_load_state_without_creating_account
    count = R::Account.count
    status, body = request_as(@alice, "/rsc/state.json")
    assert_equal 200, status
    assert_equal "0", body.fetch("wallet").fetch("balance")
    assert_equal count, R::Account.count
  end

  def test_read_only_reward_preview_is_admin_only_and_never_pays
    date = ((Time.current.utc + 8.hours).to_date - 1).iso8601
    UserVisit.find_or_create_by!(user_id: @alice.id, visited_at: date)
    SiteSetting.rsc_read_only = true
    before = [R::Account.count, R::Entry.count, R::Command.count]
    path = "/rsc/admin/rewards.json?date=#{date}&pay=true"
    assert_equal 403, request_as(@alice, path).first
    status, body = request_as(@admin, path)
    assert_equal 200, status
    assert body.fetch("rows").any? { |row| row["user_id"] == @alice.id }
    assert_equal before, [R::Account.count, R::Entry.count, R::Command.count]
  ensure
    SiteSetting.rsc_read_only = false
  end

  def test_login_reward_preserves_business_day_visit_fallback_and_boundaries
    original = @alice.attributes.slice("last_seen_at", "previous_visit_at")
    today = (Time.current.utc + 8.hours).to_date
    starts = Time.utc(today.year, today.month, today.day) - 8.hours
    UserVisit.where(user_id: @alice.id, visited_at: [today, today - 1]).delete_all
    @alice.update_columns(last_seen_at: starts, previous_visit_at: nil)
    assert_equal 1, R::Rewards.today(@alice.id)[:login]
    @alice.update_columns(last_seen_at: starts - 1.second)
    assert_equal 0, R::Rewards.today(@alice.id)[:login]
    yesterday = (today - 1).iso8601
    assert_equal 1, R::Rewards.preview(yesterday).find { |r| r[:user_id] == @alice.id }[:score]
    @alice.update_columns(last_seen_at: nil, previous_visit_at: starts)
    assert_equal 1, R::Rewards.today(@alice.id)[:login]
    @alice.update_columns(previous_visit_at: starts + 1.day)
    assert_equal 0, R::Rewards.today(@alice.id)[:login]
  ensure
    @alice.update_columns(original) if original
  end
end
