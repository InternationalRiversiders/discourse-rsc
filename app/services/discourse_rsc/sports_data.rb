# frozen_string_literal: true
module DiscourseRsc
  class SportsData
    LEAGUES = {
      "soccer" => %w[fifa.world uefa.champions eng.1 esp.1 ger.1 ita.1 fra.1 uefa.europa chn.1 uefa.euro conmebol.america afc.asian.cup fifa.worldq.afc fifa.cwc eng.fa esp.copa_del_rey],
      "basketball" => %w[nba fiba mens-olympics-basketball],
    }.freeze
    def self.date_buckets(now = Time.current)
      cursor = (now.utc.to_date - 7).beginning_of_month
      through = now.utc.to_date + 7
      buckets = []
      while cursor <= through
        buckets << cursor.strftime('%Y%m')
        cursor = cursor.next_month
      end
      buckets
    end

    def self.sync
      Safety.ensure_writable!
      # Rotate after an exhausted time budget so later leagues are not starved.
      sources = SiteSetting.rsc_sports_leagues.split("|").uniq.select do |source|
        sport, league = source.split(":", 2)
        LEAGUES.fetch(sport, []).include?(league)
      end
      cursor = Discourse.redis.get('rsc:sports-next-source').to_i
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
      tasks = sources.product(date_buckets)
      result = {}
      tasks.rotate(cursor).each do |source, dates|
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sport, league = source.split(":", 2)
        begin
          data = ProviderHttp.get("site.api.espn.com", "/apis/site/v2/sports/#{sport}/#{league}/scoreboard", dates: dates, limit: 500)
          Array(data["events"]).each { |event| ingest(event, sport: sport, league: league) }
          result[source] = result.fetch(source, true)
        rescue Error, KeyError, ArgumentError
          Audit.create!(action: "sports_sync_failed", details: { source: source }, created_at: Time.current)
          result[source] = false
        ensure
          Discourse.redis.set('rsc:sports-next-source', (tasks.index([source, dates]) + 1) % tasks.size)
        end
      end
      result['pending_recheck'] = recheck_pending
      result
    end

    def self.recheck_pending
      # A rescheduled event can disappear from every recent scoreboard. Query
      # its stable ESPN event id instead of guessing a replacement date/result.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 40
      rows = SportMatch.where(id: Prediction.where(status: 'pending').select(:sport_match_id))
        .where("starts_at < ?", 3.days.ago).where(source: 'espn')
        .where(sport: LEAGUES.keys, league: LEAGUES.values.flatten)
        .where("NOT (provider_data @> ?::jsonb)", {manual_result:true}.to_json)
        .order(Arel.sql("COALESCE(provider_data->>'rechecked_at','') ASC, id ASC")).limit(10)
      result = { checked: 0, failed: 0 }
      rows.each do |match|
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        next if match.provider_data['manual_result']
        next unless LEAGUES.fetch(match.sport, []).include?(match.league)
        id = match.external_id.to_s.split(':').last
        next unless /\A[0-9]+\z/.match?(id)
        begin
          data = ProviderHttp.get('site.api.espn.com', "/apis/site/v2/sports/#{match.sport}/#{match.league}/summary", event: id)
          event = data.fetch('header')
          raise Error.new('provider_no_data') unless event.fetch('id').to_s == id
          event = event.merge('date' => event['date'] || event.dig('competitions', 0, 'date'))
          ingest(event, sport: match.sport, league: match.league)
          result[:checked] += 1
          match.reload.with_lock { match.update!(provider_data: match.provider_data.merge('rechecked_at'=>Time.current.iso8601,'recheck_error'=>nil)) }
        rescue Error, KeyError, ArgumentError => error
          result[:failed] += 1
          match.reload.with_lock { match.update!(provider_data: match.provider_data.merge('rechecked_at'=>Time.current.iso8601,'recheck_error'=>error.class.name)) }
          Audit.create!(action: 'sports_recheck_failed', details: {match_id:match.id,error:error.class.name}, created_at:Time.current)
        end
      end
      result
    end

    def self.american(value)
      return nil if value.blank?
      value = BigDecimal(value.to_s.delete("+"))
      return nil unless value.finite? && !value.zero?
      (value.positive? ? 1 + value / 100 : 1 + 100 / value.abs).round(4).to_s("F")
    rescue ArgumentError
      nil
    end

    def self.regulation(competition, home, away)
      # Only explicit period scores prove a 90-minute result. An absent/partial
      # scoring-play feed must never be mistaken for a 0:0 draw.
      scores = [home, away].map do |team|
        lines = Array(team["linescores"])
        periods = [1, 2].map { |period| lines.find { |line| line["period"].to_i == period } }
        next unless periods.all? { |line| line && line["value"].to_s.match?(/\A\d+(?:\.0+)?\z/) }
        periods.sum { |line| line["value"].to_i }
      end
      return scores if scores.none?(&:nil?)
      nil
    end

    def self.ingest(event, sport:, league:)
      competition = event.fetch("competitions").first
      teams = competition.fetch("competitors")
      home = teams.find { |t| t["homeAway"] == "home" }
      away = teams.find { |t| t["homeAway"] == "away" }
      return unless home && away
      status = competition.dig("status", "type") || event.dig("status", "type") || {}
      name = status["name"].to_s.upcase
      state = if name.match?(/CANCEL|ABANDON|NO_CONTEST/)
        "canceled"
      elsif name.match?(/POSTPON|DELAY/)
        "postponed"
      elsif status["completed"] || status["state"] == "post"
        "finished"
      elsif status["state"] == "in"
        "live"
      else
        "scheduled"
      end
      scores = [home, away].map { |team| team["score"].to_s.match?(/\A\d+\z/) ? team["score"].to_i : nil }
      result_scores = sport == "soccer" && name.match?(/AET|PEN/) ? regulation(competition, home, away) : scores
      result = if state == "finished" && result_scores && result_scores.none?(&:nil?)
        result_scores[0] == result_scores[1] ? "draw" : (result_scores[0] > result_scores[1] ? "home" : "away")
      end
      result = nil if sport == "basketball" && result == "draw"
      moneyline = competition.dig("odds", 0, "moneyline") || {}
      odds = %w[home away draw].to_h { |pick| [pick, american(moneyline.dig(pick, "close", "odds") || moneyline.dig(pick, "open", "odds"))] }.compact
      odds.delete("draw") unless sport == "soccer"
      external = league == "fifa.world" ? event.fetch("id").to_s : "espn:#{sport}:#{league}:#{event.fetch('id')}"
      SportMatch.transaction do
        Commands.lock("sports-feed:#{external}")
        match = SportMatch.lock.find_or_initialize_by(external_id: external)
        return if match.provider_data["manual_result"]
        changed = match.status != state || match.result != result
        if match.persisted? && changed && match.predictions.where.not(status: "pending").exists?
          unless match.provider_data["correction"] == { "status" => state, "result" => result }
            Audit.create!(action: "sports_result_correction", details: { match_id: match.id, old: match.result, proposed: result, status: state }, created_at: Time.current)
          end
          match.update!(provider_data: match.provider_data.merge("correction" => { status: state, result: result }))
          return
        end
        fields = { sport: sport, league: league, home: home.dig("team", "displayName"), away: away.dig("team", "displayName"),
                   starts_at: DateTime.iso8601(event.fetch("date")).to_time, status: state, allow_draw: sport == "soccer", result: result,
                   score: { home: scores[0], away: scores[1], regulation: result_scores }, source: "espn",
                   provider_data: { stage: competition['altGameNote'] || competition.dig("notes", 0, "headline") || match.provider_data["stage"] || event['shortName'],
                     venue: competition.dig('venue', 'fullName'), status_detail: status['shortDetail'] || status['detail'] || status['description'],
                     status_name: name, synced_at: Time.current.iso8601, result_pending_review: state == "finished" && result.nil? } }
        fields[:confirmed_at] = Time.current if changed || match.confirmed_at.nil?
        fields.merge!(odds: odds, odds_at: Time.current) if odds.present? && state == "scheduled"
        match.update!(fields)
      end
    end
  end
end
