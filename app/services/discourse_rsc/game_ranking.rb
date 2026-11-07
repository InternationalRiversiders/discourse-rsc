# frozen_string_literal: true
module DiscourseRsc
  class GameRanking
    STREAK_GAMES = %w[coin dice blackjack].freeze

    def self.fetch(game:, period: 'month')
      raise Error.new('invalid_game') unless Games::NAMES.key?(game) || game == 'lottery'
      raise Error.new('invalid_request') unless %w[month all].include?(period)
      # Shared, bounded cache: opening a game never scans all rounds per visitor.
      Rails.cache.fetch("rsc:game-ranking:v1:#{game}:#{period}", expires_in: 30.seconds) do
        calculate(game: game, period: period)
      end
    end

    def self.calculate(game:, period:)
      connection = GameRound.connection
      eligible = "u.active AND NOT u.admin AND (u.suspended_till IS NULL OR u.suspended_till <= CURRENT_TIMESTAMP) AND a.status = 'active'"
      if game == 'lottery'
        cutoff = period == 'month' ? "AND d.settled_at >= #{connection.quote(30.days.ago)}" : ''
        base = <<~SQL
          SELECT d.id, t.user_id, d.settled_at,
            SUM(t.payout_units - t.quantity::numeric * #{Lottery::PRICE * Amount::UNIT}) AS net
          FROM discourse_rsc_lottery_tickets t
          JOIN discourse_rsc_lottery_draws d ON d.id = t.draw_id
          JOIN users u ON u.id = t.user_id
          JOIN discourse_rsc_accounts a ON a.key = 'wallet:' || t.user_id::text
          WHERE d.settled_at IS NOT NULL AND #{eligible} #{cutoff}
          GROUP BY d.id, t.user_id, d.settled_at
        SQL
      else
        cutoff = period == 'month' ? "AND r.settled_at >= #{connection.quote(30.days.ago)}" : ''
        base = <<~SQL
          SELECT r.id, r.user_id, r.settled_at, r.payout_units - r.stake_units AS net
          FROM discourse_rsc_game_rounds r
          JOIN users u ON u.id = r.user_id
          JOIN discourse_rsc_accounts a ON a.key = 'wallet:' || r.user_id::text
          WHERE r.game = #{connection.quote(game)} AND r.status = 'settled' AND #{eligible} #{cutoff}
        SQL
      end
      streak = STREAK_GAMES.include?(game)
      candidates = if streak
        # Refunds/pushes neither count nor break a streak. Only losses divide runs.
        <<~SQL
          runs AS (
            SELECT *, SUM(CASE WHEN net < 0 THEN 1 ELSE 0 END)
              OVER (PARTITION BY user_id ORDER BY settled_at, id ROWS UNBOUNDED PRECEDING) AS run
            FROM rounds
          ), candidates AS (
            SELECT user_id, COUNT(*) AS score, MAX(settled_at) AS achieved_at, MAX(id) AS round_id
            FROM runs WHERE net > 0 GROUP BY user_id, run
          )
        SQL
      else
        'candidates AS (SELECT user_id, net AS score, settled_at AS achieved_at, id AS round_id FROM rounds WHERE net > 0)'
      end
      rows = connection.select_all(<<~SQL).to_a
        WITH rounds AS (#{base}), #{candidates}, best AS (
          SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY score DESC, achieved_at, round_id) AS personal_rank
          FROM candidates
        )
        SELECT user_id, score, achieved_at FROM best WHERE personal_rank = 1
        ORDER BY score DESC, achieved_at, user_id LIMIT 10
      SQL
      users = User.where(id: rows.map { |r| r['user_id'] }).index_by(&:id)
      { metric: streak ? 'streak' : 'net', period: period, rows: rows.filter_map do |row|
        user = users[row['user_id'].to_i]
        next unless user
        { user: UserIdentity.serialize(user), value: streak ? row['score'].to_i : Amount.format(row['score'].to_i), achieved_at: row['achieved_at'] }
      end }
    end
  end
end
