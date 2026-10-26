# frozen_string_literal: true
module DiscourseRsc
  module ForexActivityTrader
    def self.show(user_id, section: 'positions', page: 1)
      user = User.find_by(id: user_id)
      raise Error.new('account_not_found', status: 404) unless Access.member?(user) && Account.wallet_snapshot(user_id).status == 'active'
      raise Error.new('invalid_section') unless %w[positions orders].include?(section)
      number = Integer(page.to_s, 10)
      raise Error.new('invalid_page') unless number.positive?
      entries = ForexActivity.entries.where(user_id: user_id).joins(:instrument)
        .where(discourse_rsc_instruments: { category: 'forex' })
      raise Error.new('account_not_found', status: 404) unless ForexActivity.starts_at && entries.exists?
      positions = Position.where(user_id: user_id, id: entries.select(:position_id)).includes(:instrument)
      # Close orders do not carry forex_campaign. Match their immutable settlement
      # to the activity position, then filter by fill time rather than submit time.
      fills = Journal.where(actor_user_id: user_id, operation: %w[stock_fill stock_close])
        .where('created_at >= ? AND created_at <= ?', ForexActivity.starts_at, Time.current)
        .where("metadata->>'position_id' IN (?)", entries.select(Arel.sql('position_id::text')))
      fills = fills.where('created_at < ?', ForexActivity.ends_at) if ForexActivity.ends_at
      orders = Order.where(user_id: user_id, status: 'filled')
        .where("id::text IN (?)", fills.select(Arel.sql("metadata->>'order_id'"))).includes(:instrument)
      scope = section == 'positions' ? positions : orders
      total = scope.count
      pages = [(total / 20.0).ceil, 1].max
      number = [number, pages].min
      records = scope.order(id: :desc).offset((number - 1) * 20).limit(20).to_a
      times = section == 'orders' && records.any? ? fills.where("metadata->>'order_id' IN (?)", records.map { |row| row.id.to_s })
        .pluck(Arel.sql("metadata->>'order_id'"), :created_at).to_h : {}
      rows = records.map do |record|
        row = if section == 'positions'
          Views.position(record).slice(:id, :symbol, :side, :quantity, :average, :margin, :leverage, :equity, :pnl, :valuation_basis, :valuation_at)
        else
          view = Views.order(record)
          view.slice(:id, :symbol, :side, :quantity, :status, :leverage)
            .merge(view[:details].symbolize_keys.slice(:price, :fee, :pnl, :payout, :gross, :reason))
            .merge(executed_at: times[record.id.to_s])
        end
        row.merge(display_symbol: ForexCatalog.base(record.instrument) || record.instrument.symbol,
          currency_name: ForexCatalog.name(record.instrument))
      end
      net = entries.sum { |row| row.final_units ? row.final_units.to_i : row.realized_units.to_i + row.mark_units.to_i }
      { summary: { user_id: user_id, forum_user: UserIdentity.serialize(user), net: Amount.format(net),
          trade_count: orders.count, position_count: positions.count },
        starts_at: ForexActivity.starts_at, ends_at: ForexActivity.ends_at, section: section, rows: rows,
        pagination: { page: number, pages: pages, per_page: 20, total: total, scope: "fx-activity/#{user_id}/#{section}" } }
    rescue ArgumentError, TypeError
      raise Error.new('invalid_page')
    end
  end
end
