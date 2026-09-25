# frozen_string_literal: true
module DiscourseRsc
  # Public data only. No wallet credentials or real Polymarket orders.
  module ForecastProvider
    GAMMA = "gamma-api.polymarket.com"
    CLOB = "clob.polymarket.com"
    DATA = "data-api.polymarket.com"
    def self.get(host, path, query = {})
      ProviderHttp.get(host, path, query)
    end

    def self.array(value)
      value.is_a?(String) ? JSON.parse(value) : value
    rescue JSON::ParserError
      nil
    end

    def self.decimal(value)
      number = BigDecimal(value.to_s)
      raise ArgumentError unless number.finite? && number >= 0
      number
    end

    def self.parse(raw)
      outcomes = array(raw['outcomes'])
      tokens = array(raw['clobTokenIds'])
      prices = array(raw['outcomePrices'])
      return unless outcomes.is_a?(Array) && outcomes.size == 2 && outcomes.all? { |s| s.is_a?(String) && s.present? && s.length <= 200 }
      return unless tokens.is_a?(Array) && tokens.size == 2 && tokens.uniq.size == 2 && tokens.all? { |s| /\A[0-9]{1,100}\z/.match?(s.to_s) }
      return unless prices.is_a?(Array) && prices.size == 2
      prices = prices.map { |p| decimal(p).to_s('F') }
      return unless prices.all? { |p| decimal(p) <= 1 }
      return unless /\A0x[0-9a-fA-F]{64}\z/.match?(raw['conditionId'].to_s) && /\A[0-9]{1,30}\z/.match?(raw['id'].to_s)
      return unless /\A[a-zA-Z0-9-]{1,240}\z/.match?(raw['slug'].to_s)
      question, rules = raw.values_at('question', 'description').map(&:to_s)
      return if question.blank? || question.length > 1000 || rules.blank? || rules.length > 50000
      ends = Time.iso8601(raw.fetch('endDate'))
      digest = Digest::SHA256.hexdigest(JSON.generate([raw['conditionId'], question, rules, outcomes, tokens, ends.iso8601]))
      state = raw['closed'] == true || ends <= Time.current ? 'awaiting' : (raw['active'] == true && raw['acceptingOrders'] == true && raw['enableOrderBook'] == true && raw['archived'] != true ? 'open' : 'paused')
      { external_id: raw['id'].to_s, condition_id: raw['conditionId'], question: question,
        event_title: raw.dig('events', 0, 'title').to_s.first(1000).presence || question,
        slug: raw['slug'], rules: rules, outcomes: outcomes, token_ids: tokens,
        prices: prices, ends_at: ends, volume: decimal(raw['volume24hr'] || 0), liquidity: decimal(raw['liquidity'] || 0),
        terms_digest: digest, state: state, synced_at: Time.current }
    rescue ArgumentError, TypeError, KeyError
      nil
    end

    def self.ingest(raw, featured: nil)
      attrs = parse(raw)
      return unless attrs
      ForecastMarket.transaction do
        market = ForecastMarket.lock.find_by(external_id: attrs[:external_id])
        if market
          # Never silently relabel an existing position or change its contract.
          if market.terms_digest != attrs[:terms_digest]
            market.update!(state: 'review', synced_at: Time.current) unless market.settled_at
            return market
          end
          attrs.except!(:state) if market.state == 'review' || market.settled_at
          attrs[:featured] = featured unless featured.nil?
          market.update!(attrs)
        else
          market = ForecastMarket.create!(attrs.merge(featured: featured != false))
        end
        market
      end
    end

    def self.discover
      ForecastDiscovery.discover
    end

    def self.refresh(market)
      raw = get(GAMMA, "/markets/#{market.external_id}")
      raise Error.new('forecast_unavailable', status: 503) unless raw.is_a?(Hash) && raw['id'].to_s == market.external_id
      updated = ingest(raw)
      raise Error.new('forecast_unavailable', status: 503) unless updated
      market.reload
    end

    def self.resolution(market)
      response = get(DATA, '/v2/resolutions', condition: market.condition_id)
      rows = response.is_a?(Hash) && response['data']
      raise Error.new('forecast_unavailable', status: 503) unless rows.is_a?(Array)
      row = rows.find { |r| r['condition_id'] == market.condition_id }
      raise Error.new('forecast_unavailable', status: 503) if rows.any? && !row
      row
    end

    def self.book(market, outcome)
      token = market.token_ids.fetch(outcome)
      book = get(CLOB, '/book', token_id: token)
      raise Error.new('forecast_unavailable', status: 503) unless book.is_a?(Hash) && book['asset_id'] == token && book['market'] == market.condition_id
      timestamp = decimal(book['timestamp']) / 1000
      raise Error.new('forecast_stale', status: 409) unless (Time.current.to_f - timestamp).between?(-10, 30)
      book
    end

    def self.history(market, outcome, interval)
      key = "rsc:forecast:history:#{market.id}:#{outcome}:#{interval}"
      Rails.cache.fetch(key, expires_in: 5.minutes) do
        data = get(CLOB, '/prices-history', market: market.token_ids.fetch(outcome), interval: interval, fidelity: interval == '1d' ? 15 : 60)
        Array(data['history']).last(1000).filter_map do |point|
          p = decimal(point['p']); t = Integer(point['t'])
          { t: t, p: p.to_s('F') } if p <= 1 && t.positive?
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
