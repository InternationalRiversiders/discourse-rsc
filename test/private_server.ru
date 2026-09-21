# frozen_string_literal: true
abort "Private isolated preview only" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && %w[rsc_discourse_smoke rsc_readiness_snapshot].include?(ENV["DISCOURSE_DB_NAME"]) && %w[localhost 127.0.0.1].include?(ENV["DISCOURSE_HOSTNAME"])
ENV["DISCOURSE_RUNNING_IN_RACK"] = "1"
require "/var/www/discourse/config/environment"
MessageBus.long_polling_enabled = false
use Rack::Static, urls: ["/assets", "/images", "/fonts", "/uploads"], root: "/var/www/discourse/public"
run Discourse::Application
