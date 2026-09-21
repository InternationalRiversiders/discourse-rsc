# frozen_string_literal: true
module DiscourseRsc
  class Rewards
    def self.catchup_dates(now = Time.current)
      latest = (now.utc + 8.hours - SiteSetting.rsc_daily_reward_delay_hours.hours).to_date - 1
      6.downto(0).map { |days| (latest - days).iso8601 }
    end

    def self.today(user_id)
      day = (Time.current.utc + 8.hours).to_date
      starts = Time.utc(day.year, day.month, day.day) - 8.hours
      posts = Post.joins(:topic).where(user_id: user_id, created_at: starts...(starts + 1.day), post_type: Post.types[:regular], hidden: false, deleted_at: nil)
        .where(topics: { archetype: "regular", deleted_at: nil })
      topics = posts.where(post_number: 1).count
      replies = posts.where("post_number > 1").count
      login = visit_ids(day, starts, user_id: user_id).include?(user_id) ? 1 : 0
      { date: day.iso8601, login: login, posts: topics + replies, topics: topics, replies: replies, estimated: [login + topics + replies, 10].min, enabled: SiteSetting.rsc_daily_rewards_enabled }
    end

    # Preserve the old business-day fallback: user_visits may not yet contain
    # today's visit, while last_seen_at / previous_visit_at already prove it.
    def self.visit_ids(day, starts, user_id: nil)
      visits = UserVisit.where(visited_at: day)
      users = User.where(last_seen_at: starts...(starts + 1.day))
        .or(User.where(previous_visit_at: starts...(starts + 1.day)))
      if user_id
        visits = visits.where(user_id: user_id)
        users = users.where(id: user_id)
      end
      (visits.pluck(:user_id) | users.pluck(:id)).to_set
    end

    def self.preview(date)
      day = Date.iso8601(date)
      raise Error.new("invalid_reward_date") if day >= (Time.current.utc + 8.hours).to_date
      starts = Time.utc(day.year, day.month, day.day) - 8.hours
      posts = Post.joins(:topic).where(created_at: starts...(starts + 1.day), post_type: Post.types[:regular], hidden: false)
                  .where(topics: { archetype: "regular", deleted_at: nil }).where(deleted_at: nil).group(:user_id).count
      visits = visit_ids(day, starts)
      ids = posts.keys | visits.to_a
      # System/bot identities can belong to the same groups as members, but
      # cannot own wallets. Resolve eligibility and payout markers in batches.
      members = User.joins(:groups).where(id: ids, active: true)
        .where("users.id > 0").where(groups: { id: SiteSetting.rsc_allowed_groups.to_s.split("|").map(&:to_i) })
        .distinct.index_by(&:id)
      keys = members.keys.to_h { |id| [id, "daily_reward:#{id}:daily-#{date}"] }
      paid = Command.where(key: keys.values).pluck(:key).to_set
      statuses = Account.where(kind: "wallet", user_id: members.keys).pluck(:user_id, :status).to_h
      ids.filter_map do |user_id|
        user = members[user_id]
        next unless user && !user.suspended?
        score = [posts.fetch(user_id, 0) + (visits.include?(user_id) ? 1 : 0), 10].min
        { user_id: user_id, username: user.username, score: score, paid: paid.include?(keys.fetch(user_id)), frozen: statuses.fetch(user_id, "active") != "active" }
      end
    rescue ArgumentError
      raise Error.new("invalid_reward_date")
    end

    def self.pay(date)
      Safety.ensure_writable!
      preview(date).each do |row|
        user_id, score = row.values_at(:user_id, :score)
        next if score.zero? || row[:frozen] || row[:paid]
        Commands.run(user_id: user_id, action: "daily_reward", request_id: "daily-#{date}", input: [date]) do
          units = score * Amount::UNIT
          Commands.move(user_id: user_id, action: "daily_reward", request_id: "daily-#{date}",
                        postings: { Account.issuance.id => -units, Account.wallet(user_id).id => units }, metadata: { date: date, score: score },
                        event: Commands.event(user_id, "daily_reward", { "amount" => score.to_s }))
          { score: score, date: date }
        end
      end
    end
  end
end
