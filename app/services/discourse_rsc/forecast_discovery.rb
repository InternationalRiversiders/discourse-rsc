# frozen_string_literal: true
module DiscourseRsc
  # Editorial selection only. Never change a contract or remove existing holdings.
  module ForecastDiscovery
    LIMIT = 60
    STORE = 'rsc_forecast_discovery'
    SOURCES = { 'technology' => [1401, 74], 'culture' => [596], 'economy' => [100328],
      'crypto' => [21], 'gaming' => [64], 'sports' => [1], 'world' => [2] }.freeze
    QUOTAS = { 'technology' => 12, 'culture' => 12, 'economy' => 10,
      'crypto' => 6, 'gaming' => 6, 'sports' => 8, 'world' => 6 }.freeze
    CHINA = /\b(?:china|chinese|taiwan(?:ese)?|taipei|beijing|hong kong|macau|macao|tibet(?:an)?|xinjiang|PRC|ROC|CCP|DPP|KMT|kuomintang|xi jinping|lai ching.te|william lai)\b|中国|中國|台湾|臺灣|香港|澳门|澳門|西藏|新疆|习近平|習近平/i
    POLITICS = /\b(?:politic\w*|geopolitic\w*|invad\w*|invasion|attack\w*|airstrikes?|air strikes?|military strikes?|war|military|missile\w*|blockade\w*|conflict\w*|nuclear|annex\w*|unif\w*|independen\w*|sovereign\w*|territor\w*|elect\w*|presiden\w*|premier|prime minister|leaders?|leadership|regime|communis\w*|political party|resign\w*|coup|protest\w*|sanction\w*|tariff\w*|diploma\w*|recogniz\w*|recognis\w*|strait|south china sea|government|governor|parliament|congress|minister|politburo|ceasefire|peace deal)\b|政治|战争|戰爭|入侵|进攻|進攻|军事|軍事|选举|選舉|总统|總統|统一|統一|独立|獨立|主权|主權|制裁|关税|關稅/i

    def self.excluded?(question:, event_title: '', rules: '')
      text = [question, event_title, rules].join(' ')
      text.match?(/\b(?:xi jinping|lai ching.te|william lai|dalai lama|tiananmen|CCP|kuomintang)\b|习近平|習近平|共产党|共產黨/i) || (text.match?(CHINA) && text.match?(POLITICS))
    end

    def self.metadata
      PluginStore.get(STORE, 'selection') || {}
    end

    def self.select(candidates)
      groups = candidates.group_by { |c| c[:category] }.transform_values { |rows| rows.sort_by { |c| -c[:attrs][:volume] } }
      selected, ids, events, families = [], {}, Hash.new(0), Hash.new(0)
      QUOTAS.values.max.times do
        QUOTAS.each do |category, quota|
          next if selected.count { |c| c[:category] == category } >= quota
          rows = groups[category] || []
          while (candidate = rows.shift)
            id, event, family = candidate.values_at(:id, :event, :family)
            next if ids[id] || events[event] >= (%w[sports gaming].include?(category) ? 1 : 2)
            next if family && families[family] >= 2
            selected << candidate
            ids[id] = true
            events[event] += 1
            families[family] += 1 if family
            break
          end
        end
      end
      selected.first(LIMIT)
    end

    def self.candidates(rows, category)
      rows.filter_map do |raw|
        attrs = ForecastProvider.parse(raw)
        next unless attrs && attrs[:state] == 'open' && attrs[:ends_at] > 1.hour.from_now
        next if raw['negRiskOther'] == true || excluded?(**attrs.slice(:question, :event_title, :rules))
        # Keep the existing liquidity floor; sparse categories may simply show fewer entries.
        next unless attrs[:volume] >= 1000 && attrs[:liquidity] >= 5000 && attrs[:prices].all? { |p| ForecastProvider.decimal(p).between?(BigDecimal('0.02'), BigDecimal('0.98')) }
        next if category == 'sports' && attrs[:question].match?(/Counter.Strike|Dota 2|\bLoL:|Valorant|StarCraft|League of Legends/i)
        event = raw.dig('events', 0, 'id').presence || attrs[:event_title]
        family = 'musk-posts' if attrs[:question].match?(/Elon(?: Musk)?.*(?:tweets?|posts?)/i)
        { id: attrs[:external_id], raw: raw, attrs: attrs, category: category, event: event, family: family }
      end
    end

    def self.discover
      pool = []
      # Eight bounded requests per ten-minute discovery; no per-visitor upstream requests.
      SOURCES.each do |category, tags|
        tags.each do |tag|
          rows = ForecastProvider.get(ForecastProvider::GAMMA, '/markets', closed: false, active: true,
            limit: 100, order: 'volume24hr', ascending: false, tag_id: tag)
          raise Error.new('forecast_unavailable', status: 503) unless rows.is_a?(Array)
          pool.concat(candidates(rows, category))
        end
      end
      chosen, meta = [], {}
      ForecastMarket.transaction do
        select(pool).each do |candidate|
          market = ForecastProvider.ingest(candidate[:raw], featured: true)
          next unless market && market.state == 'open'
          chosen << market.id
          meta[market.id.to_s] = { 'category' => candidate[:category], 'rank' => chosen.size }
        end
        # A valid empty result removes old recommendations, but never the market or positions.
        ForecastMarket.where(featured: true).where.not(id: chosen).update_all(featured: false)
        PluginStore.set(STORE, 'selection', meta)
      end
      chosen
    end
  end
end
