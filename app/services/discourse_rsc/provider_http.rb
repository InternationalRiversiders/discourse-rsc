# frozen_string_literal: true
require "net/http"
require "uri"
require "time"
module DiscourseRsc
  module ProviderHttp
    HOSTS = %w[query1.finance.yahoo.com api.exchange.coinbase.com api.twelvedata.com site.api.espn.com api.kraken.com www.okx.com].freeze
    # Redis is shared by web processes and Sidekiq, including both A/B containers.
    # Reserve a bounded queue slot using Redis's clock, never a process-local clock.
    RESERVE = <<~LUA
      if redis.call('EXISTS', KEYS[2]) == 1 then return -1 end
      local clock = redis.call('TIME')
      local now = tonumber(clock[1]) * 1000 + math.floor(tonumber(clock[2]) / 1000)
      local slot = math.max(tonumber(redis.call('GET', KEYS[1])) or now, now)
      if slot - now > 3000 then return -2 end
      redis.call('PSETEX', KEYS[1], 60000, slot + tonumber(ARGV[1]))
      return slot - now
    LUA
    COOL = <<~LUA
      local remaining = redis.call('PTTL', KEYS[1])
      if remaining < tonumber(ARGV[1]) then
        redis.call('PSETEX', KEYS[1], ARGV[1], '1')
      end
      return 1
    LUA

    def self.key(host, kind)
      "rsc:provider:#{host}:#{kind}"
    end

    def self.evaluate(script, keys:, argv:)
      redis = Discourse.redis
      keys = keys.map { |value| redis.respond_to?(:namespace_key) ? redis.namespace_key(value) : value }
      result = redis.eval(script, keys: keys, argv: argv)
      # Discourse may return nil while Redis is read-only. Never bypass pacing.
      raise Error.new("provider_unavailable", status: 503) unless result.is_a?(Integer)
      result
    end

    def self.reserve(host)
      interval = host == "query1.finance.yahoo.com" ? 1000 : 250
      evaluate(RESERVE, keys: [key(host, 'next'), key(host, 'cooldown')], argv: [interval]).to_i
    end

    def self.pace!(host)
      pause = reserve(host)
      raise Error.new("provider_cooldown", status: 503) if pause == -1
      raise Error.new("provider_busy", status: 503) if pause == -2
      sleep(pause / 1000.0) if pause.positive?
      # A previous in-flight request may have received 429 while we waited.
      raise Error.new("provider_cooldown", status: 503) if Discourse.redis.exists?(key(host, 'cooldown'))
    end

    def self.cooldown(host, seconds)
      evaluate(COOL, keys: [key(host, 'cooldown')], argv: [(seconds * 1000).ceil])
    end

    def self.retry_after(value)
      return 900 if value.to_s.empty?
      seconds = if /\A\d+\z/.match?(value.to_s)
        value.to_i
      else
        Time.httpdate(value) - Time.now
      end
      seconds.positive? ? seconds.ceil : 900
    rescue ArgumentError
      900
    end

    def self.get(host, path, query = {})
      raise Error.new("provider_unavailable", status: 503) unless HOSTS.include?(host)
      pace!(host)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
      uri = URI::HTTPS.build(host: host, path: path, query: URI.encode_www_form(query))
      body = +""
      Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 4, read_timeout: 8, write_timeout: 4) do |http|
        request = Net::HTTP::Get.new(uri.request_uri, { "User-Agent" => "Discourse-RSC/0.2", "Accept" => "application/json", "Connection" => "close" })
        http.request(request) do |response|
          code = response.code.to_i
          cooldown(host, retry_after(response['retry-after'])) if code == 429
          cooldown(host, 900) if code == 403
          cooldown(host, 120) if code >= 500
          raise Error.new("provider_http_#{response.code}", status: 503) unless code == 200
          response.read_body do |part|
            raise Error.new("provider_unavailable", status: 503) if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            body << part
            raise Error.new("provider_response_too_large", status: 503) if body.bytesize > 8_000_000
          end
        end
      end
      JSON.parse(body, decimal_class: BigDecimal)
    rescue JSON::ParserError, Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      cooldown(host, 120)
      raise Error.new("provider_unavailable", status: 503)
    end
  end
end
