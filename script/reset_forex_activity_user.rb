# frozen_string_literal: true
# Explicit operator-only maintenance. Not loaded by the plugin or exposed by API.
# Removes one user's activity FX history, rebases surviving ledger snapshots,
# and retains only an aggregate completion receipt for idempotence (no raw rows).
module DiscourseRsc
  class ForexActivityUserReset
    ACTION = 'forex_activity_direct_reset'
    TABLES = %w[accounts journals entries events commands orders positions forex_activity_entries].freeze

    def self.run(user_id:, reset_key:, apply: false)
      raise ArgumentError, 'A stable operation key is required' unless /\A[a-z0-9_-]{8,80}\z/.match?(reset_key)
      user = User.find(user_id)
      result = ActiveRecord::Base.transaction do
        db = ActiveRecord::Base.connection
        db.execute("SET LOCAL lock_timeout = '3s'")
        db.execute("SET LOCAL statement_timeout = '30s'")
        Commands.lock('rsc-exchange')
        Commands.lock('rsc-fx-activity-awards')
        receipt = Audit.where(action: ACTION).find_by("details->>'reset_key' = ?", reset_key)
        if receipt
          raise 'Operation key belongs to another user' unless receipt.details['user_id'] == user_id
          next receipt.details.merge('already_applied' => true)
        end
        # Block all ledger writers while immutable triggers are temporarily
        # relaxed. DDL, deletes, rebasing and trigger restoration are atomic.
        db.execute("LOCK TABLE #{TABLES.map { |t| "discourse_rsc_#{t}" }.join(', ')} IN ACCESS EXCLUSIVE MODE")
        start = ForexActivity.starts_at or raise 'No activity start'
        activity = ForexActivity.entries.where(user_id: user_id).to_a
        position_ids = activity.map(&:position_id)
        orders = Order.joins(:instrument).where(user_id: user_id, discourse_rsc_instruments: { category: 'forex' }).where('discourse_rsc_orders.created_at >= ?', start).order(:id).to_a
        order_ids = orders.map(&:id)
        positions = Position.joins(:instrument).where(user_id: user_id, discourse_rsc_instruments: { category: 'forex' }).to_a
        raise 'Pre-activity FX position would be affected' unless (positions.map(&:id) - position_ids).empty?
        raise 'Non-activity opening would be affected' if orders.any? { |o| o.status == 'filled' && o.side != 'close' && o.details['forex_campaign'] != ForexActivity::KEY }
        wallet = Account.find_by!(key: "wallet:#{user_id}")
        escrow_keys = position_ids.map { |id| "position:#{id}" } + order_ids.map { |id| "order:#{id}" }
        escrows = Account.where(key: escrow_keys).to_a
        journals = Journal.where(actor_user_id: user_id).where("(operation IN ('stock_reserve','stock_fill','stock_close','stock_refund') AND metadata->>'order_id' IN (?)) OR (operation = 'stock_margin' AND metadata->>'position_id' IN (?))", order_ids.map(&:to_s), position_ids.map(&:to_s)).to_a
        journal_ids = journals.map(&:id)
        raise 'Unrecognized escrow movement' unless (Entry.where(account_id: escrows.map(&:id)).distinct.pluck(:journal_id) - journal_ids).empty?
        changes = Entry.where(journal_id: journal_ids).group(:account_id).sum(:units).transform_values(&:to_i)
        accounts = Account.where(id: changes.keys).to_a
        allowed = escrow_keys + [wallet.key, 'system:exchange']
        raise 'Unrelated account would be affected' unless accounts.all? { |a| allowed.include?(a.key) }
        raise 'Unbalanced deletion' unless changes.values.sum.zero?
        before_sums = Entry.where(account_id: changes.keys).group(:account_id).sum(:units)
        accounts.each do |a|
          raise 'Ledger already inconsistent' unless a.balance_units.to_i == before_sums.fetch(a.id, 0).to_i
          restored = a.balance_units.to_i - changes.fetch(a.id)
          raise 'Restored account would be negative' if a.kind != 'system' && restored.negative?
          raise 'Escrow would not be empty' if escrow_keys.include?(a.key) && !restored.zero?
        end
        target_commands = Command.where("key LIKE ?", "stock_%:#{user_id}:%").where("result->>'order_id' IN (?) OR result->>'position_id' IN (?)", order_ids.map(&:to_s), position_ids.map(&:to_s))
        events = Event.where(journal_id: journal_ids)
        notification_ids = events.pluck(:notification_id).compact
        badge_ids = Badge.where(name: ForexActivity::BADGES.values.map(&:first) + ForexActivity::LEGACY_BADGES.values).pluck(:id)
        user_badges = UserBadge.where(user_id: user_id, badge_id: badge_ids)
        summary = { 'reset_key'=>reset_key, 'user_id'=>user.id, 'username'=>user.username,
          'orders'=>orders.size, 'open_positions'=>positions.size, 'journals'=>journals.size,
          'activity_entries'=>activity.size, 'badges'=>user_badges.count,
          'wallet_before'=>Amount.format(wallet.balance_units.to_i),
          'wallet_after'=>Amount.format(wallet.balance_units.to_i-changes.fetch(wallet.id,0)) }
        next summary.merge('preview'=>true) unless apply
        raise 'No activity trades to reset' if orders.empty? && activity.empty?
        db.execute('ALTER TABLE discourse_rsc_journals DISABLE TRIGGER discourse_rsc_immutable_journals')
        db.execute('ALTER TABLE discourse_rsc_entries DISABLE TRIGGER discourse_rsc_immutable_entries')
        # Native destruction updates notification counters and badge titles.
        Notification.where(id: notification_ids, user_id: user_id).find_each(&:destroy!)
        Notification.where(user_id: user_id, notification_type: Notification.types[:granted_badge]).find_each do |n|
          n.destroy! if badge_ids.include?(n.data_hash['badge_id'].to_i)
        end
        user_badges.includes(:badge, :user).each { |ub| BadgeGranter.revoke(ub) }
        profile = user.user_profile
        profile.update!(granted_title_badge_id:nil) if profile && badge_ids.include?(profile.granted_title_badge_id)
        events.delete_all
        Entry.where(journal_id: journal_ids).delete_all
        Journal.where(id: journal_ids).delete_all
        target_commands.delete_all
        Order.where(id: order_ids).delete_all
        Position.where(id: positions.map(&:id)).delete_all
        ForexActivityEntry.where(id: activity.map(&:id)).delete_all
        accounts.each { |a| a.update!(balance_units: a.balance_units.to_i - changes.fetch(a.id)) }
        # Surviving wallet/system snapshots must reflect the history after
        # removal. Posting amounts, journals and other users' balances stay intact.
        if changes.any?
          ids = changes.keys.map { |id| Integer(id) }.join(',')
          db.execute(<<~SQL)
            UPDATE discourse_rsc_entries e SET balance_after_units = b.balance
            FROM (SELECT id, SUM(units) OVER (PARTITION BY account_id ORDER BY id ROWS UNBOUNDED PRECEDING) AS balance
                  FROM discourse_rsc_entries WHERE account_id IN (#{ids})) b
            WHERE e.id = b.id AND e.balance_after_units <> b.balance
          SQL
        end
        db.execute('ALTER TABLE discourse_rsc_entries ENABLE TRIGGER discourse_rsc_immutable_entries')
        db.execute('ALTER TABLE discourse_rsc_journals ENABLE TRIGGER discourse_rsc_immutable_journals')
        after_sums = Entry.where(account_id: changes.keys).group(:account_id).sum(:units)
        accounts.each { |a| raise 'Restored ledger inconsistent' unless a.reload.balance_units.to_i == after_sums.fetch(a.id,0).to_i }
        Account.where(id:escrows.map(&:id)).delete_all
        raise 'Deleted records remain' if Journal.where(id:journal_ids).exists? || Order.where(id:order_ids).exists? || Position.where(id:position_ids).exists?
        Audit.create!(action:ACTION, actor_user_id:Discourse.system_user.id, details:summary, created_at:Time.current)
        summary
      end
      if apply
        %w[equity portfolio_equity return_pct total_pnl realized_pnl pnl trade_count].each do |sort|
          Discourse.cache.delete("rsc:leaderboard:v3:#{sort}:#{SiteSetting.rsc_allowed_groups}")
        end
      end
      result
    end
  end
end
