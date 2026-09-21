# frozen_string_literal: true

abort "Refusing to run outside isolated Discourse database" unless
  ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_discourse_smoke"

require "minitest/autorun"
require "/rsc/db/migrate/20260920000000_create_rsc_accounting"
ActiveRecord::Migration.verbose = false
CreateRscAccounting.new.migrate(:up) unless ActiveRecord::Base.connection.table_exists?(:discourse_rsc_accounts)

class DiscourseSmokeTest < Minitest::Test
  def setup
    Discourse.cache.delete('rsc:trading-hours')
    ActiveRecord::Base.connection.execute("TRUNCATE discourse_rsc_events, discourse_rsc_entries, discourse_rsc_journals, discourse_rsc_accounts RESTART IDENTITY CASCADE")
    ActiveRecord::Base.connection.execute("TRUNCATE discourse_rsc_commands, discourse_rsc_instruments, discourse_rsc_positions, discourse_rsc_orders, discourse_rsc_sport_matches, discourse_rsc_predictions, discourse_rsc_packets, discourse_rsc_packet_claims RESTART IDENTITY CASCADE")
    ActiveRecord::Base.connection.execute("TRUNCATE discourse_rsc_searches, discourse_rsc_audits, discourse_rsc_market_requests, discourse_rsc_history_caches, discourse_rsc_exemptions, discourse_rsc_legacy_records RESTART IDENTITY CASCADE")
    SiteSetting.rsc_market_data_enabled = false
    SiteSetting.rsc_sports_data_enabled = false
    SiteSetting.rsc_high_risk_enabled = false
    SiteSetting.rsc_native_trial_enabled = true
    SiteSetting.rsc_sports_settlement_delay_seconds = 300
    SiteSetting.rsc_read_only = false
    SiteSetting.rsc_enabled = true
    SiteSetting.rsc_daily_outgoing_count = 20
    SiteSetting.rsc_daily_outgoing_amount = "300"
    @group = Group.find_or_create_by!(name: "rsc_test_members")
    SiteSetting.rsc_allowed_groups = @group.id.to_s
    SiteSetting.create_topic_allowed_groups = @group.id.to_s
    @admin = make_user("rsc_admin", admin: true)
    @alice = make_user("rsc_alice")
    @bob = make_user("rsc_bob")
    [@alice, @bob].each { |user| @group.add(user) }
    [@alice, @bob].each(&:reload)
  end

  def make_user(name, admin: false)
    User.find_by(username: name) || User.create!(username: name, email: "#{name}@example.com",
                                               password: SecureRandom.hex(32), active: true,
                                               approved: true, admin: admin)
  end

  def test_native_issue_transfer_and_notification
    issued = DiscourseRsc::Wallet.issue(actor: @admin, recipient: @alice, amount: "10.000000000000000001",
                                        reason: "isolated test", request_id: SecureRandom.uuid)
    assert issued.journal.persisted?
    result = DiscourseRsc::Wallet.transfer(actor: @alice, recipient: @bob, amount: "2.50", request_id: SecureRandom.uuid)
    assert_equal "2.5", DiscourseRsc::Account.wallet(@bob.id).balance
    assert_equal "7.500000000000000001", DiscourseRsc::Account.wallet(@alice.id).balance
    event = DiscourseRsc::Event.find_by!(journal_id: result.journal.id)
    DiscourseRsc::NotificationDelivery.deliver(event)
    count = Notification.where(user_id: @bob.id).count
    DiscourseRsc::NotificationDelivery.deliver(event.reload)
    assert_equal count, Notification.where(user_id: @bob.id).count
    notification = Notification.find(event.reload.notification_id)
    assert_equal Notification.types[:custom], notification.notification_type
    assert_equal "2.5", notification.data_hash["rsc_amount"]
  end

  def test_native_membership_and_admin_authorization
    stranger = make_user("rsc_stranger")
    assert_raises(DiscourseRsc::Error) do
      DiscourseRsc::Wallet.transfer(actor: stranger, recipient: @alice, amount: "1", request_id: SecureRandom.uuid)
    end
    assert_raises(DiscourseRsc::Error) do
      DiscourseRsc::Wallet.issue(actor: @alice, recipient: @bob, amount: "1", reason: "no", request_id: SecureRandom.uuid)
    end
  end

  def test_native_routes_are_loaded
    route = Rails.application.routes.recognize_path("/rsc/transfers", method: :post)
    assert_equal "discourse_rsc/wallet", route[:controller]
    assert_equal "transfer", route[:action]
  end

  def test_daily_limits_apply_across_transfers_and_tips
    DiscourseRsc::Wallet.issue(actor: @admin, recipient: @alice, amount: "10", reason: "test", request_id: SecureRandom.uuid)
    SiteSetting.rsc_daily_outgoing_amount = "3"
    DiscourseRsc::Wallet.transfer(actor: @alice, recipient: @bob, amount: "2", request_id: SecureRandom.uuid)
    category = Category.find_or_create_by!(name: "RSC public test") { |item| item.user_id = @admin.id }
    category.set_permissions(everyone: :full)
    category.save!
    post = PostCreator.create!(@bob, category: category.id,
                              title: "Native RSC test topic #{SecureRandom.hex(4)}",
                              raw: "A public post for isolated native tip testing. #{SecureRandom.hex(32)}")
    error = assert_raises(DiscourseRsc::Error) do
      DiscourseRsc::Wallet.transfer(actor: @alice, recipient: @bob, post: post, amount: "2", request_id: SecureRandom.uuid)
    end
    assert_equal "daily_amount_limit", error.code
    assert_equal "8", DiscourseRsc::Account.wallet(@alice.id).balance
    result = DiscourseRsc::Wallet.transfer(actor: @alice, recipient: @bob, post: post, amount: "1", request_id: SecureRandom.uuid)
    event = DiscourseRsc::Event.find_by!(journal_id: result.journal.id)
    DiscourseRsc::NotificationDelivery.deliver(event)
    assert_equal post.topic_id, Notification.find(event.reload.notification_id).topic_id
  end

  def test_http_routes_require_login_and_plugin_enabled
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "rsc.test"
    session.https!
    session.get "/rsc/wallet.json"
    assert_includes [401, 403], session.response.status
    SiteSetting.rsc_enabled = false
    session.get "/rsc/wallet.json"
    assert_includes [403, 404], session.response.status
  end

  def test_http_transfer_uses_authenticated_sender_and_replays_once
    DiscourseRsc::Wallet.issue(actor: @admin, recipient: @alice, amount: "10", reason: "test", request_id: SecureRandom.uuid)
    key = ApiKey.create!(user_id: @alice.id, created_by_id: @admin.id, description: "isolated RSC test")
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! "rsc.test"
    session.https!
    headers = { "Api-Key" => key.key, "Api-Username" => @alice.username }
    params = { recipient_user_id: @bob.id, amount: "2", request_id: SecureRandom.uuid, from_user_id: @admin.id }
    session.post "/rsc/transfers.json", params: params, headers: headers, as: :json
    assert_equal 201, session.response.status, session.response.body
    session.post "/rsc/transfers.json", params: params, headers: headers, as: :json
    assert_equal 200, session.response.status, session.response.body
    assert JSON.parse(session.response.body).fetch("replayed")
    assert_equal "8", DiscourseRsc::Account.wallet(@alice.id).balance
    assert_equal "2", DiscourseRsc::Account.wallet(@bob.id).balance
  end
end
