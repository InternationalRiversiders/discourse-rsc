# frozen_string_literal: true
module DiscourseRsc
  class Campaign
    KEY = "world-cup-2026-knockout-with-third-place-v1"
    STAGES = ["Round of 32", "Round of 16", "Quarterfinals", "Semifinals", "3rd-Place Match", "Final"].map { |stage| "FIFA World Cup, #{stage}" }.freeze
    BADGES = { silver: "绿茵观察家", gold: "足坛预言家" }.freeze

    def self.preview
      legacy_matches = LegacyRecord.where(source_table: "world_cup_matches").pluck(:data).index_by { |row| row["external_id"].to_s }
      matches = SportMatch.where(league: "fifa.world", starts_at: Time.utc(2026)...Time.utc(2027)).select do |match|
        STAGES.include?(match.provider_data["stage"] || legacy_matches.dig(match.external_id, "stage"))
      end
      # This historical campaign used final scores (including extra time), as
      # its original settlement script did. Do not change prediction settlement
      # or substitute today's 90-minute market rules for historical eligibility.
      results = matches.to_h do |match|
        legacy = legacy_matches[match.external_id]
        result = match.result
        if legacy && legacy["home_score"] && legacy["away_score"]
          home, away = legacy.values_at("home_score", "away_score").map(&:to_i)
          result = home == away ? "draw" : (home > away ? "home" : "away")
        end
        [match.id, result]
      end
      ready = matches.size == 32 && matches.all? { |match| match.status == "finished" && results[match.id].present? }
      predictions = Prediction.where(sport_match_id: matches.map(&:id)).to_a
      ready &&= predictions.all? { |p| p.status == (p.pick == results.fetch(p.sport_match_id) ? "won" : "lost") }
      old = LegacyRecord.where(source_table: "world_cup_campaign_rewards").pluck(:data)
        .select { |row| row["campaign_key"] == KEY }.index_by { |row| row["discourse_user_id"].to_i }
      rows = predictions.group_by(&:user_id).map do |user_id, items|
        count = items.size
        correct = items.count { |p| p.status == "won" }
        prior = old[user_id] || {}
        if prior.present? && (prior["participation_count"].to_i != count || prior["correct_count"].to_i != correct || BigDecimal(prior.fetch("rebate_rsc")) != count)
          ready = false
        end
        done = Command.exists?(key: "campaign_award:#{user_id}:#{KEY}")
        { user_id: user_id, username: User.find_by(id: user_id)&.username, participation_count: count, correct_count: correct, rebate: count.to_s,
          paid: done || prior["rsc_issuance_id"].present? || prior["rsc_paid_at"].present?,
          silver_eligible: correct >= 5, gold_eligible: correct >= 10,
          silver_granted: done || prior["silver_badge_grant_id"].present? || prior["silver_granted_at"].present?,
          gold_granted: done || prior["gold_badge_grant_id"].present? || prior["gold_granted_at"].present? }
      end
      # Missing imported participants may never be silently forgotten.
      ready &&= (old.keys - rows.map { |row| row[:user_id] }).empty?
      rows.each { |row| row[:pending] = !row[:paid] || (row[:silver_eligible] && !row[:silver_granted]) || (row[:gold_eligible] && !row[:gold_granted]) }
      { key: KEY, ready: ready, matches: matches.size, participants: rows.size, pending: rows.count { |row| row[:pending] },
        rebate_pending: rows.reject { |row| row[:paid] }.sum { |row| row[:participation_count] }.to_s, rows: rows }
    end

    def self.apply(actor: nil)
      Safety.ensure_writable!
      raise Error.new("admin_required", status: 403) if actor && !Access.admin?(actor)
      plan = preview
      raise Error.new("campaign_not_ready", status: 409) unless plan[:ready]
      plan[:rows].select { |row| row[:pending] }.each do |row|
        Commands.run(user_id: row[:user_id], action: "campaign_award", request_id: KEY,
          input: row.slice(:user_id, :participation_count, :correct_count, :rebate)) do
          user = User.find(row[:user_id])
          Access.ensure_member!(user)
          unless row[:paid]
            amount = Amount.positive(row[:rebate])
            Ledger.post(operation: "campaign_rebate", actor_user_id: nil, request_id: "wc2026-#{user.id}",
              postings: { Account.issuance.id => -amount, Account.wallet(user.id).id => amount },
              metadata: { campaign: KEY, user_id: user.id, amount: row[:rebate] },
              events: [Commands.event(user.id, "issuance", { amount: row[:rebate], actor_user_id: actor&.id })])
          end
          BADGES.each do |tier, name|
            next unless row[:"#{tier}_eligible"] && !row[:"#{tier}_granted"]
            badge = Badge.find_by(id: SiteSetting.public_send("rsc_campaign_#{tier}_badge_id"), name: name)
            raise Error.new("campaign_badge_missing", status: 409) unless badge && !badge.multiple_grant?
            BadgeGranter.grant(badge, user, granted_by: actor || Discourse.system_user) || raise(Error.new("campaign_badge_missing"))
          end
          Audit.create!(actor_user_id: actor&.id, action: "campaign_award", details: row.slice(:user_id, :rebate).merge(campaign: KEY), created_at: Time.current)
          { paid: true }
        end
      end
      preview
    end
  end
end
