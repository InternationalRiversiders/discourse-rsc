# frozen_string_literal: true
require 'socket'
require 'openssl'
require 'timeout'
require 'websocket/driver'
module DiscourseRsc
  # Owned by Sidekiq, not web workers. Redis elects one subscriber across A/B.
  class CryptoStream
    URL = 'wss://ws-feed.exchange.coinbase.com'.freeze
    HOST = 'ws-feed.exchange.coinbase.com'.freeze
    LOCK = Mutex.new
    RENEW = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('EXPIRE', KEYS[1], 20) else return 0 end"
    RELEASE = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end"
    class Transport
      def initialize(io); @io = io; end
      def url; URL; end
      def write(bytes); Timeout.timeout(5) { @io.write(bytes) }; end
    end

    def self.enabled?
      SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled && SiteSetting.rsc_crypto_stream_enabled &&
        SiteSetting.rsc_market_data_enabled && !Safety.read_only?
    end

    def self.ensure_running
      return unless enabled?
      db = RailsMultisite::ConnectionManagement.current_db
      LOCK.synchronize do
        return if @stopping
        @threads ||= {}
        return if @threads[db]&.alive?
        @threads[db] = Thread.new do
          RailsMultisite::ConnectionManagement.with_connection(db) do
            new.run(stop: -> { @stopping || !enabled? })
          end
        rescue StandardError => error
          Rails.logger.warn("RSC stream stopped: #{error.class}")
        ensure
          ActiveRecord::Base.connection_pool.release_connection
        end
      end
    end

    def self.stop_all
      @stopping = true
    end

    def self.quote(message, received_at: Time.current)
      return unless message['type'] == 'ticker' && /\A[A-Z0-9]+-USD\z/.match?(message['product_id'].to_s)
      source = Time.iso8601(message.fetch('time'))
      return unless source <= received_at + 5 && source >= received_at - 120
      data = { 'price' => MarketData.decimal(message.fetch('price')), 'source_time' => source.utc.iso8601(6),
        'received_at' => received_at.utc.iso8601(6), 'source' => 'coinbase_ws', 'delay_seconds' => 0,
        'change_basis' => '24h', 'local_currency' => 'USD', 'local_price' => MarketData.decimal(message.fetch('price')) }
      {'best_bid'=>'bid','best_ask'=>'ask','open_24h'=>'previous_close'}.each do |field, key|
        data[key] = MarketData.decimal(message[field]) if message[field].present?
      end
      {'high_24h'=>'high','low_24h'=>'low'}.each { |field, key| data[key] = MarketData.optional_price(message[field]) }
      data
    rescue Error, KeyError, ArgumentError
      nil
    end

    def run(stop: -> { false }, max_seconds: nil)
      ending = max_seconds && monotonic + max_seconds
      retry_seconds = 1
      until stop.call || (ending && monotonic >= ending)
        token = SecureRandom.uuid
        if Discourse.redis.set('rsc:coinbase-stream:lease', token, nx: true, ex: 20)
          begin
            session(token, stop: stop, seconds: ending ? [ending - monotonic, 300].min : 300)
            retry_seconds = 1
          rescue StandardError => error
            Rails.logger.warn("RSC stream reconnect: #{error.class}")
            retry_seconds = [retry_seconds * 2, 30].min
          ensure
            ProviderHttp.evaluate(RELEASE, keys: ['rsc:coinbase-stream:lease'], argv: [token])
          end
        end
        ActiveRecord::Base.connection_pool.release_connection
        # Small interruptible sleeps keep disabled/read-only/shutdown responsive.
        (retry_seconds * 2).times do
          break if stop.call || (ending && monotonic >= ending)
          sleep 0.5
        end
      end
    end

    def session(token, stop:, seconds:)
      products = Instrument.where(active: true, provider: 'coinbase').pluck(:provider_symbol, :id).to_h
        .select { |code, _| /\A[A-Z0-9]+-USD\z/.match?(code.to_s) }
      return if products.empty?
      tcp = Socket.tcp(HOST, 443, connect_timeout: 5)
      context = OpenSSL::SSL::SSLContext.new
      context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.hostname = HOST
      ssl.sync_close = true
      Timeout.timeout(5) { ssl.connect }
      ssl.post_connection_check(HOST)
      driver = WebSocket::Driver.client(Transport.new(ssl), max_length: 1_048_576)
      closed = false
      pending = {}
      last_message = monotonic
      last_flush = monotonic
      last_renew = monotonic
      started = monotonic
      count = 0
      driver.on(:open) { driver.text(JSON.generate(type: 'subscribe', product_ids: products.keys, channels: %w[ticker heartbeat])) }
      driver.on(:close) { closed = true }
      driver.on(:error) { closed = true }
      driver.on(:message) do |event|
        last_message = monotonic
        begin
          message = JSON.parse(event.data)
          if message.is_a?(Hash)
            raise Error.new('provider_unavailable') if message['type'] == 'error'
            id = products[message['product_id']]
            quote = id && self.class.quote(message)
            pending[id] = quote if quote
          end
        rescue JSON::ParserError
          # Ignore malformed frames; a stream without valid quotes never enables trading.
        end
      end
      driver.start
      until closed || stop.call || monotonic - started >= seconds
        raise Error.new('provider_unavailable') if monotonic - last_message > 45
        if monotonic - last_renew >= 5
          raise Error.new('stream_lease_lost') unless ProviderHttp.evaluate(RENEW, keys: ['rsc:coinbase-stream:lease'], argv: [token]) == 1
          last_renew = monotonic
          Discourse.redis.set('rsc:stream:status', JSON.generate(connected: true, products: products.size, persisted_quotes: count, heartbeat_at: Time.current.iso8601), ex: 60)
        end
        if ssl.pending.positive? || IO.select([ssl], nil, nil, 0.25)
          bytes = ssl.read_nonblock(65_536, exception: false)
          break if bytes.nil?
          driver.parse(bytes) if bytes.is_a?(String)
        end
        if monotonic - last_flush >= 1
          raise Error.new('stream_lease_lost') unless ProviderHttp.evaluate(RENEW, keys: ['rsc:coinbase-stream:lease'], argv: [token]) == 1
          break if stop.call
          pending.each do |id, quote|
            item = Instrument.find_by(id: id, active: true, provider: 'coinbase')
            next unless item && products[item.provider_symbol] == id
            MarketData.record_quote(item, quote, stream: true)
            count += 1
          end
          pending.clear
          last_flush = monotonic
          ActiveRecord::Base.connection_pool.release_connection
        end
      end
    ensure
      ssl&.close
      tcp&.close unless tcp&.closed?
      ActiveRecord::Base.connection_pool.release_connection
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
