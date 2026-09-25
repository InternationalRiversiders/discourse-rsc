# frozen_string_literal: true
module DiscourseRsc
  module ForecastCatalog
    CACHE = 'rsc:forecast:browse:v1'
    PER_PAGE = 24

    def self.id(value)
      value = value.to_s
      raise Error.new('forecast_invalid_reference') unless /\A[0-9]{1,30}\z/.match?(value)
      value
    end

    def self.eligible(raw)
      attrs = ForecastProvider.parse(raw)
      return unless attrs && attrs[:state] == 'open' && attrs[:ends_at] > Time.current && raw['negRiskOther'] != true
      return if ForecastDiscovery.excluded?(**attrs.slice(:question, :event_title, :rules))
      attrs
    end

    def self.entry(raw, category = 'other')
      attrs = eligible(raw)
      return unless attrs
      attrs.slice(:external_id, :question, :event_title, :outcomes, :prices, :volume, :liquidity, :ends_at, :slug).stringify_keys.merge(
        'event_id' => (raw.dig('events',0,'id').presence || attrs[:event_title]).to_s,
        'category' => category, 'created_at' => raw['createdAt'].to_s)
    end

    def self.publish(entries)
      Rails.cache.write(CACHE, { 'entries' => entries.uniq { |e| e['external_id'] }, 'updated_at' => Time.current.iso8601 }, expires_in: 1.hour)
    end

    def self.raw(external_id)
      external_id = id(external_id)
      result = ForecastProvider.get(ForecastProvider::GAMMA, "/markets/#{external_id}")
      raise Error.new('forecast_unavailable') unless result.is_a?(Hash) && result['id'].to_s == external_id
      raise Error.new('forecast_not_eligible') unless eligible(result)
      result
    end

    def self.preview(external_id)
      Rails.cache.fetch("rsc:forecast:preview:#{id(external_id)}", expires_in: 5.minutes) { raw(external_id).merge('_rsc_fetched_at' => Time.current.iso8601) }
    end

    def self.reference(query)
      return [preview(query)] if /\A[0-9]{1,30}\z/.match?(query)
      uri = URI.parse(query)
      raise Error.new('forecast_invalid_reference') unless %w[https http].include?(uri.scheme) && %w[polymarket.com www.polymarket.com].include?(uri.host) && uri.userinfo.nil? && [80,443].include?(uri.port)
      match = %r{\A/(market|event)/([a-zA-Z0-9-]{1,240})(?:/([a-zA-Z0-9-]{1,240}))?/?\z}.match(uri.path)
      raise Error.new('forecast_invalid_reference') unless match
      kind, slug, market_slug = match.captures
      kind, slug = 'market', market_slug if market_slug && kind == 'event'
      raise Error.new('forecast_invalid_reference') if market_slug && match[1] != 'event'
      Rails.cache.fetch("rsc:forecast:reference:#{kind}:#{slug}", expires_in: 5.minutes) do
        row = ForecastProvider.get(ForecastProvider::GAMMA, kind == 'market' ? "/markets/slug/#{slug}" : "/events/slug/#{slug}")
        raise Error.new('forecast_unavailable') unless row.is_a?(Hash)
        if kind == 'event'
          Array(row['markets']).first(500).map { |market| market.merge('events' => [row.slice('id','title')]) }
        else
          [row]
        end
      end
    rescue URI::InvalidURIError
      raise Error.new('forecast_invalid_reference')
    end

    def self.browse(actor:, query: '', category: 'all', order: 'balanced', page: 1, event_id: '')
      query = query.to_s.strip.first(512)
      snapshot = Rails.cache.read(CACHE) || { 'entries' => [] }
      entries = snapshot['entries']
      if query.match?(%r{\A(?:https?://|[0-9]{1,30}\z)}i)
        entries = reference(query).filter_map { |row| entry(row) }
        query = ''
      end
      # Existing listed titles supply cached Chinese search terms without translating the entire catalog.
      listed = ForecastMarket.where(external_id: entries.map { |row| row['external_id'] }).index_by(&:external_id)
      requests = ForecastRequest.where(user_id: actor.id, external_id: entries.map { |row| row['external_id'] }).index_by(&:external_id)
      entries = entries.map do |row|
        market = listed[row['external_id']]
        translated = market && ForecastTranslation.presentation(market)
        row.merge('question' => translated ? translated[:question] : row['question'], 'original_question' => row['question'],
          'outcomes' => translated ? translated[:outcomes] : row['outcomes'], 'market_id' => market&.id,
          'request_status' => requests[row['external_id']]&.status)
      end
      counts = entries.group_by { |row| row['category'] }.transform_values(&:size)
      entries.select! { |row| row['category'] == category } unless category == 'all'
      entries.select! { |row| [row['question'],row['original_question'],row['event_title']].join(' ').downcase.include?(query.downcase) } if query.present?
      entries.sort_by! { |row| order == 'newest' ? row['created_at'] : row['volume'].to_f }
      entries.reverse!
      grouped = event_id.to_s.empty?
      entries.select! { |row| row['event_id'] == event_id.to_s } unless grouped
      market_count = entries.size
      groups = entries.group_by { |row| row['event_id'] }
      entries = groups.values.map { |rows| rows.first.merge('related_count' => rows.size) } if grouped
      if grouped && order == 'balanced'
        buckets = entries.group_by { |row| row['category'] }.values
        entries = (0...(buckets.map(&:size).max || 0)).flat_map { |i| buckets.filter_map { |bucket| bucket[i] } }
      end
      pages = [(entries.size.to_f / PER_PAGE).ceil, 1].max
      page = [[page.to_i, 1].max, pages].min
      { markets: entries.slice((page-1)*PER_PAGE, PER_PAGE) || [], total: entries.size, market_count: market_count, grouped: grouped, page: page, pages: pages, categories: counts, updated_at: snapshot['updated_at'] }
    end
  end
end
