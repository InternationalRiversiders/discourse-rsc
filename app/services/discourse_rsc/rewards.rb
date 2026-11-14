# frozen_string_literal: true
module DiscourseRsc
  class Rewards
    STREAK_START = Date.new(2026, 11, 14).freeze
    VISIT_START = Date.new(2026, 11, 14).freeze
    VISIT_STORE = "rsc_beijing_visits:"
    HISTORY_STORE = "rsc_reward_history_v1"

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
      streak = login_streak_data(day, [user_id], limit: nil).fetch(user_id)
      streak = login_streak_data(day - 1, [user_id], limit: nil).fetch(user_id) if login.zero?
      login_streak = streak[:count]
      login_reward = login.zero? ? 0 : (day >= STREAK_START ? streak_reward(login_streak) : login)
      { date: day.iso8601, login_streak: login_streak, login_streak_estimated: streak[:estimated], login_reward: login_reward, daily_max: day >= STREAK_START ? 20 : 10, login: login, posts: topics + replies, topics: topics, replies: replies, estimated: score(day, login_reward, topics + replies), enabled: SiteSetting.rsc_daily_rewards_enabled }
    end

    # Timestamp-backed visits use Beijing dates, including reconstructed history.
    def self.record_visit(user_id, stamp = Time.current)
      return unless user_id.to_i > 0 && stamp
      day = (stamp.utc + 8.hours).to_date
      return if stamp > Time.current
      DB.exec(<<~SQL, store: "#{VISIT_STORE}#{user_id}", day: day.iso8601, stamp: stamp.utc.iso8601(6))
        INSERT INTO plugin_store_rows (plugin_name,key,type_name,value) VALUES (:store,:day,'String',:stamp)
        ON CONFLICT (plugin_name,key) DO UPDATE SET type_name='String',
          value=CASE WHEN plugin_store_rows.type_name='String' THEN LEAST(plugin_store_rows.value,EXCLUDED.value) ELSE EXCLUDED.value END
      SQL
    end

    def self.visit_ids(day, starts, user_id: nil)
      users = User.where(last_seen_at: starts...(starts + 1.day))
        .or(User.where(previous_visit_at: starts...(starts + 1.day)))
      users = users.where(id: user_id) if user_id
      rows = PluginStoreRow.where(key: day.iso8601)
      rows = user_id ? rows.where(plugin_name: "#{VISIT_STORE}#{user_id}") : rows.where("plugin_name LIKE ?", "#{VISIT_STORE}%")
      ids = rows.pluck(:plugin_name).map { |name| name.delete_prefix(VISIT_STORE).to_i } | users.pluck(:id)
      if day < VISIT_START
        visits = UserVisit.joins(:user).where(visited_at: day).where("users.created_at < ?", starts + 1.day)
        visits = visits.where(user_id: user_id) if user_id
        ids |= visits.pluck(:user_id)
      end
      ids.to_set
    end

    # 28 consecutive days suffice to reach the cap. Batch the lookback instead
    # of querying once per member, and retain today's visit fallback.
    def self.login_rewards(day, ids)
      login_streaks(day, ids).transform_values { |count| streak_reward(count) }
    end

    def self.streak_reward(count)
      count.zero? ? 0 : [1 + (count - 1) / 3, 10].min
    end

    def self.login_streaks(day, ids, limit: 28)
      login_streak_data(day, ids, limit: limit).transform_values { |value| value[:count] }
    end

    def self.login_streak_data(day, ids, limit: 28)
      return legacy_streak_data(day, ids, limit: limit) if day < VISIT_START
      return {} if ids.empty?
      dates = Hash.new { |h, id| h[id] = Set.new }
      rows = PluginStoreRow.where(plugin_name: ids.map { |id| "#{VISIT_STORE}#{id}" }, key: VISIT_START.iso8601..day.iso8601)
      rows = rows.where("key >= ?", (day - limit + 1).iso8601) if limit
      rows.pluck(:plugin_name, :key).each { |store, date| dates[store.delete_prefix(VISIT_STORE).to_i] << Date.iso8601(date) }
      User.where(id: ids).pluck(:id, :last_seen_at, :previous_visit_at).each do |id, last, previous|
        [last, previous].compact.each do |stamp|
          date = (stamp.utc + 8.hours).to_date
          dates[id] << date if date >= VISIT_START && date <= day
        end
      end
      history = PluginStore.get_all(HISTORY_STORE, ids.map(&:to_s))
      ids.to_h do |id|
        count = 0
        count += 1 while (!limit || count < limit) && dates[id].include?(day - count)
        estimated = false
        if day - count == VISIT_START - 1 && (!limit || count < limit)
          baseline = history[id.to_s] || {}
          extra = baseline.fetch('count', 0)
          extra = [extra, limit - count].min if limit
          count += extra
          estimated = extra > 0 && baseline.fetch('estimated', false)
        end
        [id, { count: count, estimated: estimated }]
      end
    end

    # One-time deployment operation, never run while rendering a wallet.
    def self.initialize_history!
      PluginStoreRow.transaction do
        DB.exec("SELECT pg_advisory_xact_lock(748321951)")
        return if PluginStore.get(HISTORY_STORE, 'complete')
        backfill_history!
        User.where('id > 0').find_in_batches(batch_size: 500) do |users|
          legacy_streak_data(VISIT_START - 1, users.map(&:id), limit: nil).each do |id, data|
            PluginStore.set(HISTORY_STORE, id.to_s, data.merge(date: (VISIT_START - 1).iso8601, source: data[:estimated] ? 'utc_date_credit_with_beijing_registration_bound' : 'timestamp_evidence_beijing'))
          end
        end
        PluginStore.set(HISTORY_STORE, 'complete', true)
      end
    end

    def self.legacy_streak_data(day, ids, limit: 28)
      return {} if ids.empty?
      dates = Hash.new { |h, id| h[id] = Set.new }
      visits = UserVisit.where(user_id: ids).where("visited_at <= ?", [day, VISIT_START - 1].min)
      visits = visits.where("visited_at >= ?", day - limit + 1) if limit
      visits.pluck(:user_id, :visited_at).each { |id, date| dates[id] << date }
      proven = Hash.new { |h, id| h[id] = Set.new }
      rows = PluginStoreRow.where(plugin_name: ids.map { |id| "#{VISIT_STORE}#{id}" })
        .where("key <= ?", day.iso8601)
      rows = rows.where("key >= ?", (day - limit + 1).iso8601) if limit
      rows.pluck(:plugin_name, :key).each { |name, date| proven[name.delete_prefix(VISIT_STORE).to_i] << Date.iso8601(date) }
      registered = {}
      User.where(id: ids).pluck(:id, :created_at, :first_seen_at, :last_seen_at, :previous_visit_at).each do |id, created, first, last, previous|
        registered[id] = (created.utc + 8.hours).to_date
        [first, last, previous].compact.each do |stamp|
          date = (stamp.utc + 8.hours).to_date
          proven[id] << date if date <= day
        end
      end
      ids.to_h do |id|
        # A date-only UTC visit cannot establish which Beijing day was visited.
        # Keep this as explicitly estimated credit, never before registration.
        available = dates[id] | proven[id]
        count = 0
        estimated = false
        while (!limit || count < limit) && available.include?(day - count) && registered[id] && day - count >= registered[id]
          estimated ||= !proven[id].include?(day - count)
          count += 1
        end
        [id, { count: count, estimated: estimated }]
      end
    end

    def self.backfill_history!
      sources = ["SELECT user_id, created_at AS stamp FROM posts", "SELECT acting_user_id AS user_id, created_at AS stamp FROM user_actions"]
      sources << "SELECT user_id, created_at AS stamp FROM chat_messages" if ActiveRecord::Base.connection.table_exists?(:chat_messages)
      DB.exec(<<~SQL, prefix: VISIT_STORE, format: 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        INSERT INTO plugin_store_rows (plugin_name, key, type_name, value)
        SELECT :prefix || e.user_id::text, (e.stamp + interval '8 hours')::date::text, 'String', to_char(MIN(e.stamp), :format)
        FROM (#{sources.join(" UNION ALL ")}) e
        JOIN users u ON u.id = e.user_id
        WHERE e.user_id > 0 AND e.stamp >= u.created_at AND e.stamp <= CURRENT_TIMESTAMP
        GROUP BY e.user_id, (e.stamp + interval '8 hours')::date
        ON CONFLICT (plugin_name, key) DO UPDATE SET type_name='String',
          value=CASE WHEN plugin_store_rows.type_name='String' THEN LEAST(plugin_store_rows.value,EXCLUDED.value) ELSE EXCLUDED.value END
      SQL
    end

    def self.score(day, login_reward, posts)
      day >= STREAK_START ? login_reward + [posts, 10].min : [login_reward + posts, 10].min
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
      login_amounts = day >= STREAK_START ? login_rewards(day, members.keys) : {}
      ids.filter_map do |user_id|
        user = members[user_id]
        next unless user && !user.suspended?
        login_reward = day >= STREAK_START ? login_amounts.fetch(user_id, 0) : (visits.include?(user_id) ? 1 : 0)
        score = self.score(day, login_reward, posts.fetch(user_id, 0))
        { user_id: user_id, username: user.username, forum_user: UserIdentity.serialize(user), score: score, paid: paid.include?(keys.fetch(user_id)), frozen: statuses.fetch(user_id, "active") != "active" }
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
                        postings: { Account.issuance.id => -units, Account.wallet(user_id).id => units }, metadata: { date: date, score: score })
          { score: score, date: date }
        end
      end
    end
  end
end
