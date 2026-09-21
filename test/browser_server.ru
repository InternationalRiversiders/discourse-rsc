# frozen_string_literal: true
abort "Isolated test only" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && ENV["DISCOURSE_DB_NAME"] == "rsc_discourse_smoke"
ENV["DISCOURSE_RUNNING_IN_RACK"] = "1"
require "/var/www/discourse/config/environment"
MessageBus.long_polling_enabled = false
use Rack::Static, urls: ["/assets", "/images", "/fonts", "/uploads"], root: "/var/www/discourse/public"
run Discourse::Application
