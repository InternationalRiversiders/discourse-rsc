# frozen_string_literal: true
# name: discourse-rsc
# about: Native RSC accounting and community economy for Discourse
# version: 0.2.0
# authors: Riverside
# required_version: 2026.9.0-latest

gem 'websocket-extensions', '0.1.5', require: false
gem 'websocket-driver', '0.8.2', require_name: 'websocket/driver'

enabled_site_setting :rsc_enabled
register_svg_icon "coins"
register_svg_icon "triangle-exclamation"
register_asset "stylesheets/rsc.scss"

module ::DiscourseRsc
  PLUGIN_NAME = "discourse-rsc"
end

require_relative "lib/discourse_rsc/error"
require_relative "lib/discourse_rsc/amount"
require_relative "lib/discourse_rsc/engine"

after_initialize do
  %w[
    app/models/discourse_rsc/account
    app/models/discourse_rsc/journal
    app/models/discourse_rsc/entry
    app/models/discourse_rsc/event
    app/models/discourse_rsc/command
    app/models/discourse_rsc/instrument
    app/models/discourse_rsc/position
    app/models/discourse_rsc/order
    app/models/discourse_rsc/sport_match
    app/models/discourse_rsc/prediction
    app/models/discourse_rsc/packet
    app/models/discourse_rsc/packet_claim
    app/models/discourse_rsc/audit
    app/models/discourse_rsc/market_request
    app/models/discourse_rsc/search
    app/models/discourse_rsc/history_cache
    app/models/discourse_rsc/exemption
    app/models/discourse_rsc/legacy_record
    app/services/discourse_rsc/safety
    app/services/discourse_rsc/ledger
    app/services/discourse_rsc/access
    app/services/discourse_rsc/wallet
    app/services/discourse_rsc/commands
    app/services/discourse_rsc/red_packets
    app/services/discourse_rsc/packet_sharing
    app/services/discourse_rsc/sports
    app/services/discourse_rsc/market_sessions
    app/services/discourse_rsc/trading_rules
    app/services/discourse_rsc/exchange
    app/services/discourse_rsc/catalog
    app/services/discourse_rsc/provider_http
    app/services/discourse_rsc/market_data
    app/services/discourse_rsc/crypto_stream
    app/services/discourse_rsc/sports_presentation
    app/services/discourse_rsc/sports_data
    app/services/discourse_rsc/risk
    app/services/discourse_rsc/valuation
    app/services/discourse_rsc/market_listing
    app/services/discourse_rsc/user_identity
    app/services/discourse_rsc/wallet_history
    app/services/discourse_rsc/views
    app/services/discourse_rsc/reports
    app/services/discourse_rsc/administration
    app/services/discourse_rsc/admin_reports
    app/services/discourse_rsc/legacy_market
    app/services/discourse_rsc/legacy_rules
    app/services/discourse_rsc/legacy_import
    app/services/discourse_rsc/campaign
    app/services/discourse_rsc/rewards
    app/services/discourse_rsc/notification_delivery
    app/controllers/discourse_rsc/wallet_controller
    app/controllers/discourse_rsc/dashboard_controller
    app/controllers/discourse_rsc/features_controller
    app/controllers/discourse_rsc/public_packets_controller
    app/jobs/regular/discourse_rsc_notify
    app/jobs/regular/discourse_rsc_provider_poll
    app/jobs/regular/discourse_rsc_manual_sync
    app/jobs/scheduled/discourse_rsc_sync_data
    app/jobs/scheduled/discourse_rsc_business_tick
    app/jobs/scheduled/discourse_rsc_trading_tick
    app/jobs/scheduled/discourse_rsc_deliver_notifications
  ].each { |path| require_relative path }

  Oneboxer.singleton_class.prepend(DiscourseRsc::LegacyPacketOnebox)
  InlineOneboxer.singleton_class.prepend(DiscourseRsc::LegacyPacketInlineOnebox)
  Oneboxer.register_local_handler("discourse_rsc/public_packets") do |_url, route|
    DiscourseRsc::PacketSharing.html(DiscourseRsc::PacketSharing.local_packet(route))
  end
  InlineOneboxer.register_local_handler("discourse_rsc/public_packets") do |_url, route|
    packet = DiscourseRsc::PacketSharing.local_packet(route)
    { url: DiscourseRsc::PacketSharing.url(packet), title: DiscourseRsc::PacketSharing.title(packet) } if packet
  end

  # These guards remain effective even while the plugin is disabled for cutover.
  UserMerger.prepend(DiscourseRsc::Safety::MergeGuard)
  UserDestroyer.prepend(DiscourseRsc::Safety::DeleteGuard)
  User.before_destroy(prepend: true) { DiscourseRsc::Safety.ensure_user_retained!(self) }

  add_to_serializer(:current_user, :rsc_member) { SiteSetting.rsc_enabled && DiscourseRsc::Access.member?(object) }

  add_to_serializer(:current_user, :rsc_admin) { SiteSetting.rsc_enabled && DiscourseRsc::Access.admin?(object) }

  Discourse::Application.routes.append { mount ::DiscourseRsc::Engine, at: "/rsc" }
end

# Streams stop promptly when Sidekiq stops accepting work. The next process's
# trading schedule takes over after the short Redis lease expires.
Sidekiq.configure_server do |config|
  config.on(:quiet) { DiscourseRsc::CryptoStream.stop_all }
  config.on(:shutdown) { DiscourseRsc::CryptoStream.stop_all }
end
