# frozen_string_literal: true
module DiscourseRsc
  # Quarantine observations before they reach marks, executions or liquidations.
  # A cache hit is not a second observation. No prices are averaged or invented.
  module ForexQuoteGuard
    VERSION = 1
    MATCH_BPS = 5 # 0.05%: cross-feed agreement / candidate cluster tolerance.
    FIELDS = %w[price source source_time received_at inverse_rate base_currency pricing_method delay_seconds].freeze

    def self.pending?(quote)
      quote.dig('verification', 'status') == 'pending'
    end

    def self.fresh?(quote, now = Time.current)
      at = Time.iso8601(quote.fetch('source_time'))
      received = Time.iso8601(quote.fetch('received_at'))
      at.between?(now - 120, now + 5) && received.between?(now - 120, now + 5) &&
        Amount.positive(quote.fetch('price')).positive? && quote['source'].present?
    rescue Error, KeyError, ArgumentError, TypeError
      false
    end

    def self.near?(a, b, bps = MATCH_BPS)
      x, y = Amount.positive(a.fetch('price')), Amount.positive(b.fetch('price'))
      (x - y).abs * 10_000 < [x, y].min * bps
    end

    def self.review_bps(previous, incoming)
      seconds = (Time.iso8601(incoming.fetch('source_time')) - Time.iso8601(previous.fetch('source_time'))).abs
      # 0.1% within a minute. Gaps widen the review band, up to 0.5%;
      # they never make a source switch exempt from the agreement check.
      [10 * Math.sqrt([seconds, 60].max / 60.0), 50].min.floor
    end

    def self.apply(previous, incoming, now: Time.current)
      return nil unless fresh?(incoming, now)
      baseline = previous['price'].present? && previous['source_time'].present? && previous['source'].present? && !previous['legacy_snapshot'] &&
        previous['pricing_method'] == incoming['pricing_method']
      return accepted(incoming, 'initial') unless baseline
      state = previous['verification'] || {}
      observations = (state['observations'] || {}).deep_dup
      if observations.empty? && fresh?(previous, now)
        observations[previous['source']] = [previous.slice(*FIELDS)]
      end
      source = incoming.fetch('source')
      samples = Array(observations[source]).select { |s| Time.iso8601(s['source_time']) >= now - 300 }
      last = samples.last
      at = Time.iso8601(incoming.fetch('source_time'))
      if last.nil? || at > Time.iso8601(last['source_time'])
        samples = [] if last && !near?(last, incoming)
        samples << incoming.slice(*FIELDS)
      elsif at == Time.iso8601(last['source_time']) && last['price'] != incoming['price']
        # A revision at the same timestamp can retract a spike, but cannot
        # manufacture multiple confirmations at that timestamp.
        samples = [incoming.slice(*FIELDS)]
      end
      observations[source] = samples.last(3)
      observations.select! { |_, values| values.last && Time.iso8601(values.last['source_time']) >= now - 300 }
      others = observations.reject { |key, _| key == source }.values.filter_map do |values|
        values.last if fresh?(values.last, now)
      end
      conflict = others.any? { |q| !near?(q, incoming) }
      agreement = others.any? { |q| near?(q, incoming) }
      switched = previous['source'] != source
      jump = !near?(previous, incoming, review_bps(previous, incoming))
      needs_review = pending?(previous) || jump || (switched && !near?(previous, incoming)) || conflict
      reason = if !needs_review
        switched ? 'source_continuity' : 'continuous'
      elsif !conflict && agreement
        'cross_source'
      elsif !conflict && !switched && near?(previous, incoming)
        'recovered'
      elsif !conflict && samples.size >= 3 &&
          (Time.iso8601(samples.last['source_time']) - Time.iso8601(samples.first['source_time'])) >= 60 &&
          samples.all? { |sample| near?(sample, incoming) }
        'successive_observations'
      end
      return accepted(incoming, reason) if reason
      previous.merge('verification' => {
        'version' => VERSION, 'status' => 'pending', 'reason' => conflict || switched ? 'source_disagreement' : 'price_jump',
        'since' => state['since'] || now.iso8601(6), 'checked_at' => now.iso8601(6),
        'observations' => observations, 'candidate' => incoming.slice(*FIELDS)
      })
    end

    def self.accepted(quote, reason)
      quote.merge('verification' => { 'version' => VERSION, 'status' => 'verified',
        'method' => reason, 'checked_at' => Time.current.iso8601(6) })
    end

    def self.execution_details(instrument)
      return {} unless instrument.category == 'forex'
      { 'executed_at' => Time.current.iso8601(6), 'execution_quote' => instrument.quote.slice(*FIELDS, 'verification') }
    end
  end
end
