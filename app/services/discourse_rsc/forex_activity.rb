# frozen_string_literal: true
module DiscourseRsc
  class ForexActivity
    KEY = 'fx-kurumi-2026'
    TITLE = 'FX 战士久留美 · 河畔外汇修行'
    FEATURED = %w[FX:JPY FX:EUR FX:GBP FX:AUD FX:CAD FX:CHF].freeze
    NAMES = { 'JPY'=>'日元', 'EUR'=>'欧元', 'GBP'=>'英镑', 'AUD'=>'澳元', 'CAD'=>'加元', 'CHF'=>'瑞郎', 'CNY'=>'人民币', 'HKD'=>'港元', 'INR'=>'印度卢比', 'KRW'=>'韩元', 'NZD'=>'新西兰元', 'SGD'=>'新加坡元' }.freeze
    BADGES = {
      debut: ['FX战士 · 初入汇市', '活动期间首次完成一笔新外汇仓位的开仓。', 3],
      practice: ['FX战士 · 外汇修行者', '活动期间在三个不同日期完成活动仓位开仓或加仓（按 UTC+8 统计）。', 2],
      survivor: ['FX战士 · 汇市幸存者', '活动结束时活动净盈亏不为负，且活动仓位没有被强平。', 1]
    }.freeze

    def self.time(value)
      Time.iso8601(value.to_s) if value.present?
    rescue ArgumentError
      nil
    end
    def self.starts_at; time(SiteSetting.rsc_forex_activity_starts_at); end
    def self.ends_at; time(SiteSetting.rsc_forex_activity_ends_at); end
    def self.active?(now = Time.current)
      SiteSetting.rsc_forex_activity_enabled && starts_at && now >= starts_at && (!ends_at || now < ends_at)
    end
    def self.active_for?(instrument); instrument.category == 'forex' && active?; end
    def self.currency_name(instrument)
      NAMES[instrument.symbol.delete_prefix('FX:')] || instrument.name
    end
    def self.entry(position)
      ForexActivityEntry.find_by(position_id: position.id, campaign_key: KEY) if position&.persisted?
    end
    def self.fee_bps(instrument, position: nil)
      return instrument.fee_bps unless instrument.category == 'forex'
      return entry(position)&.fee_bps || instrument.fee_bps if position
      active_for?(instrument) ? SiteSetting.rsc_forex_activity_fee_bps : instrument.fee_bps
    end
    def self.confirmation?(instrument, leverage = 1)
      instrument.category == 'forex' && (active_for?(instrument) || leverage > 10)
    end
    def self.order_details(instrument, position, side)
      return {} unless instrument.category == 'forex'
      counted = side != 'close' && active_for?(instrument) && (!position || entry(position))
      { 'fee_bps'=>fee_bps(instrument, position: position), 'forex_campaign'=>counted ? KEY : nil,
        'fx_confirmation'=>confirmation?(instrument, position&.leverage || 1) }
    end
    def self.record_open(position, order, fee, fresh:)
      return unless order.details['forex_campaign'] == KEY && active?
      row = entry(position)
      return unless row || fresh
      row ||= ForexActivityEntry.new(campaign_key: KEY, user_id: position.user_id, instrument_id: position.instrument_id,
        position_id: position.id, fee_bps: order.details.fetch('fee_bps'), opened_at: Time.current)
      row.realized_units = row.realized_units.to_i - fee
      row.trade_days = (row.trade_days + [(Time.current.utc + 8.hours).to_date.to_s]).uniq
      row.mark_price_units ||= Amount.positive(position.instrument.quote["price"])
      row.marked_at ||= time(position.instrument.quote["source_time"]) || Time.current
      row.save!
      mark(row, position)
    end
    # Called before every close, including automatic liquidation. This freezes
    # deadline valuations before a later close can remove or shrink the position.
    def self.prepare_close(position)
      row = entry(position)
      mark(row, position) if row
      row
    end
    def self.record_close(row, position, quantity, net, kind)
      return unless row
      if !row.finalized_at && (!ends_at || Time.current < ends_at)
        row.realized_units = row.realized_units.to_i + net
        row.liquidated ||= kind == 'stock_liquidated'
      end
      row.closed_at = Time.current if quantity == position.quantity_units.to_i
      row.mark_units = 0 if row.closed_at && !row.finalized_at
      row.save!
    end
    def self.mark(row, position)
      return if row.finalized_at
      ending = ends_at && Time.current >= ends_at
      if position
        # Select a source observation, never a later quote at an earlier cutoff.
        cutoff = ending ? ends_at : Time.current
        candidates = position.instrument.history.filter_map do |point|
          at = time(point['at']); next unless at && at <= cutoff
          [at, Amount.positive(point['price'])]
        rescue Error
          nil
        end
        q = position.instrument.quote
        source = time(q['source_time'])
        candidates << [source, Amount.positive(q['price'])] if source && source <= cutoff && q['price'].present?
        candidates << [row.marked_at, row.mark_price_units.to_i] if row.marked_at && row.marked_at <= cutoff && row.mark_price_units.to_i.positive?
        at, price = candidates.max_by(&:first)
        if price
          margin = position.margin_units.to_i
          # Same cash floor as exchange settlement, including estimated exit fee.
          exit_price = price
          fee = position.quantity_units.to_i * exit_price / Amount::UNIT * row.fee_bps / 10_000
          row.mark_units = [margin + Exchange.pnl(position, exit_price) - fee, 0].max - margin
          row.mark_price_units = price
          row.marked_at = at
        end
      else
        row.mark_units = 0
      end
      if ending
        row.final_units = row.realized_units.to_i + row.mark_units.to_i
        row.finalized_at = Time.current
      end
      row.save!
    end
    def self.entries; ForexActivityEntry.where(campaign_key: KEY); end
    def self.results
      entries.order(:id).group_by(&:user_id).map do |user_id, rows|
        { user_id: user_id, score: rows.sum { |r| r.final_units ? r.final_units.to_i : r.realized_units.to_i + r.mark_units.to_i },
          days: rows.flat_map(&:trade_days).uniq.size, trades: rows.size, liquidated: rows.any?(&:liquidated),
          final: rows.all?(&:finalized_at), valuation_at: rows.filter_map(&:marked_at).min }
      end.sort_by { |r| [-r[:score], r[:user_id]] }.each_with_index.map { |row, i| row.merge(rank: i + 1) }
    end
    def self.presentation(user_id: nil, page: 1)
      rows = results
      pages = [(rows.size / 30.0).ceil, 1].max
      page = [[page.to_i, 1].max, pages].min
      mine = rows.find { |r| r[:user_id] == user_id }
      visible = rows.slice((page - 1) * 30, 30) || []
      users = User.where(id: visible.map { |r| r[:user_id] }).index_by(&:id)
      serialize = ->(row) { row && row.except(:score).merge(net: Amount.format(row[:score]), forum_user: UserIdentity.serialize(users[row[:user_id]] || row[:user_id])) }
      summary.merge(rows: visible.map { |r| serialize.call(r) }, me: serialize.call(mine), total: rows.size, page: page, pages: pages)
    end
    def self.summary
      { key: KEY, title: TITLE, visible: starts_at.present?, active: !!active?, starts_at: starts_at, ends_at: ends_at,
        ended: !!(ends_at && Time.current >= ends_at), fee_bps: SiteSetting.rsc_forex_activity_fee_bps,
        max_leverage: 100, featured: FEATURED, end_label: ends_at ? nil : '持续至本季动画播完，最终话日期确认后公布截止时间' }
    end
    def self.tick
      return unless starts_at
      ForexActivityEntry.transaction do
        Commands.lock('rsc-exchange')
        rows = entries.where(finalized_at: nil).to_a
        positions = Position.where(id: rows.map(&:position_id)).includes(:instrument).index_by(&:id)
        rows.each { |row| mark(row, positions[row.position_id]) }
      end
      award
    end
    def self.award
      rows = results
      return if rows.empty?
      ForexActivityEntry.transaction do
        Commands.lock('rsc-fx-activity-awards')
        badges = BADGES.to_h do |key, (name, description, tier)|
          badge = Badge.find_or_initialize_by(name: name)
          if badge.new_record?
            badge.assign_attributes(description: description, long_description: description, badge_type_id: tier,
              multiple_grant: false, allow_title: true, enabled: true, icon: 'chart-line')
            badge.save!
          end
          [key, badge]
        end
        users = User.where(id: rows.map { |r| r[:user_id] }).index_by(&:id)
        rows.each do |row|
          user = users[row[:user_id]]; next unless user
          eligible = [:debut]
          eligible << :practice if row[:days] >= 3
          eligible << :survivor if row[:final] && row[:score] >= 0 && !row[:liquidated]
          eligible.each do |key|
            badge = badges.fetch(key)
            next if UserBadge.exists?(user_id: user.id, badge_id: badge.id)
            BadgeGranter.grant(badge, user, granted_by: Discourse.system_user)
          end
        end
      end
    end
  end
end
