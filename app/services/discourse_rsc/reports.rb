# frozen_string_literal: true
module DiscourseRsc
  class Reports
    def self.portfolio(user_id, data: nil)
      data ||= portfolio_data([user_id])
      positions = data[:positions].fetch(user_id, [])
      orders = data[:orders].fetch(user_id, [])
      predictions = data[:predictions].fetch(user_id, [])
      forecasts = data.fetch(:forecasts, {}).fetch(user_id, [])
      forecast_cost = forecasts.select { |p| p.state == "open" }.sum { |p| p.cost_units.to_i }
      wallet = data[:wallets][user_id]
      valuations = positions.map { |position| Valuation.position(position, data[:prices][position.instrument_id]) }
      pnl = valuations.map { |value| value[:pnl] }
      basis = valuations.any? { |value| value[:basis] == "cost" } ? "cost" : (valuations.any? { |value| value[:basis] == "last_quote" } ? "last_quote" : "current")
      balance = wallet&.balance_units.to_i
      margin = positions.sum { |p| p.margin_units.to_i }
      reserved = orders.select { |o| o.status == "pending" }.sum { |o| o.reserved_units.to_i }
      # Imported orders are lifecycle records, not authoritative executions.
      # Realized legacy P&L comes from actual fills, including liquidation caps.
      filled = orders.select { |o| o.status == "filled" && !o.details.key?("legacy_id") }
      legacy_trades = data[:legacy_trades].fetch(user_id, [])
      realized = filled.sum do |order|
        d = order.details
        if order.side != "close"
          -BigDecimal(d.fetch("fee", "0"))
        elsif d["payout"] && d["margin"]
          BigDecimal(d["payout"]) - BigDecimal(d["margin"])
        else
          BigDecimal(d.fetch("pnl", "0")) - BigDecimal(d.fetch("fee", "0"))
        end
      end
      realized += legacy_trades.sum do |trade|
        if %w[buy long short].include?(trade["side"])
          -BigDecimal(trade.fetch("fee_rsc"))
        else
          BigDecimal(trade.fetch("net_rsc")) - BigDecimal(trade.fetch("margin_rsc"))
        end
      end
      stakes = predictions.select { |p| p.status == "pending" }.sum { |p| p.stake_units.to_i }
      realized += BigDecimal(Amount.format(predictions.reject { |p| p.status == "pending" }.sum { |p| p.payout_units.to_i - p.stake_units.to_i }))
      realized += BigDecimal(Amount.format(forecasts.sum { |p| p.realized_units.to_i }))
      stakes += forecast_cost
      basis = "cost" if forecast_cost.positive?
      realized += data[:adjustments].fetch(user_id.to_s, 0)
      unrealized = pnl.none?(&:nil?) ? pnl.sum : nil
      total_equity = unrealized && balance + reserved + margin + stakes + unrealized
      total_profit = unrealized && realized + BigDecimal(Amount.format(unrealized))
      social = data[:social].fetch(wallet&.id, 0).to_i + Amount.parse(data[:legacy_social].fetch(user_id.to_s, BigDecimal("0")).abs.to_s("F")) * (data[:legacy_social].fetch(user_id.to_s, 0) < 0 ? -1 : 1)
      capital = total_equity && BigDecimal(Amount.format(total_equity - social)) - total_profit
      return_pct = capital && capital.positive? ? (total_profit * 100 / capital).truncate(2).to_s("F") : "0"
      { valuation_basis: basis, valuation_at: valuations.filter_map { |value| value[:at] }.min, return_pct: return_pct, portfolio_equity: unrealized && Amount.format(margin + stakes + unrealized), user_id: user_id, username: data[:users][user_id]&.username, forum_user: UserIdentity.serialize(data[:users][user_id]), balance: Amount.format(balance), margin: Amount.format(margin),
        reserved: Amount.format(reserved), equity: total_equity && Amount.format(total_equity), pnl: unrealized && Amount.format(unrealized), realized_pnl: realized.to_s("F"),
        total_pnl: unrealized && total_profit.to_s("F"), trade_count: filled.size + legacy_trades.size }
    end

    def self.portfolio_data(ids)
      wallets = Account.where(kind: "wallet", user_id: ids).index_by(&:user_id)
      positions = Position.where(user_id: ids).includes(:instrument).to_a
      prices = positions.map(&:instrument).uniq(&:id).to_h { |i| [i.id, Valuation.mark(i)] }
      legacy = LegacyRecord.where("data ->> 'discourse_user_id' IN (?)", ids.map(&:to_s))
      {
        legacy_trades: legacy.where(source_table: "exchange_trades").pluck(:data).group_by { |row| row["discourse_user_id"].to_i },
        forecasts: ForecastPosition.where(user_id: ids).to_a.group_by(&:user_id),
        wallets: wallets, positions: positions.group_by(&:user_id), prices: prices,
        users: User.where(id: ids).index_by(&:id),
        orders: Order.where(user_id: ids).to_a.group_by(&:user_id), predictions: Prediction.where(user_id: ids).to_a.group_by(&:user_id),
        adjustments: legacy.where(source_table: "exchange_pnl_adjustments").group(Arel.sql("data ->> 'discourse_user_id'")).sum(Arel.sql("(data ->> 'amount_rsc')::numeric")),
        social: Entry.joins(:journal).where(account_id: wallets.values.map(&:id)).where(discourse_rsc_journals: { operation: %w[transfer post_tip red_packet_open red_packet_claim red_packet_refund] }).group(:account_id).sum(:units),
        legacy_social: legacy.where(source_table: "ledger_entries").where("data ->> 'type' IN ('transfer', 'post_tip', 'red_packet_fund', 'red_packet_claim', 'red_packet_refund')")
          .group(Arel.sql("data ->> 'discourse_user_id'")).sum(Arel.sql("CASE WHEN data ->> 'direction' = 'credit' THEN (data ->> 'amount_rsc')::numeric ELSE -(data ->> 'amount_rsc')::numeric END")),
      }
    end

    def self.leaderboard(sort = "equity")
      raise Error.new("invalid_sort") unless %w[equity portfolio_equity return_pct total_pnl realized_pnl pnl trade_count].include?(sort)
      Discourse.cache.fetch("rsc:leaderboard:v3:#{sort}:#{SiteSetting.rsc_allowed_groups}", expires_in: 1.minute) do
        # Only trading participants; frozen/suspended/non-member wallets omitted.
        ids = sort == "equity" ? (Account.where(kind: "wallet").pluck(:user_id) | LegacyRecord.where(source_table: "users").pluck(Arel.sql("data ->> 'discourse_user_id'")).map(&:to_i)) : (Order.where(status: "filled").distinct.pluck(:user_id) | Prediction.distinct.pluck(:user_id) | Position.distinct.pluck(:user_id))
        ids = User.where(id: ids, active: true).where("suspended_till IS NULL OR suspended_till <= ?", Time.current)
          .joins(:group_users).where(group_users: { group_id: SiteSetting.rsc_allowed_groups.to_s.split("|").map(&:to_i) }).distinct.pluck(:id)
        frozen_ids = Account.where(user_id: ids, kind: "wallet").where.not(status: "active").pluck(:user_id)
        ids -= frozen_ids
        # Node's legacy localeCompare uses the English ICU collation. Preserve
        # its final tie-break where PostgreSQL provides it, with a stable fallback.
        collation = ActiveRecord::Base.connection.select_value("SELECT collname FROM pg_collation WHERE collname = 'en-US-x-icu'")
        names = User.where(id: ids).order(Arel.sql(collation ? 'username COLLATE "en-US-x-icu"' : 'username')).pluck(:id)
        name_rank = names.each_with_index.to_h
        data = portfolio_data(ids)
        rows = ids.map { |id| portfolio(id, data: data) }
        rows.select { |r| !r[sort.to_sym].nil? }.sort_by { |r| [-BigDecimal(r[sort.to_sym].to_s), -BigDecimal(r[:total_pnl]), -BigDecimal(r[:return_pct]), -BigDecimal(r[:portfolio_equity]), name_rank.fetch(r[:user_id])] }.map do |row|
          row.slice(:valuation_basis, :valuation_at, :return_pct, :portfolio_equity, :user_id, :username, :forum_user, :equity, :pnl, :realized_pnl, :total_pnl, :trade_count)
        end
      end
    end

    def self.relation_page(scope, page: 1, per_page: 50)
      number=Integer(page.to_s,10);raise Error.new("invalid_page") unless number.positive?
      total=scope.count;pages=[(total.to_f/per_page).ceil,1].max;number=[number,pages].min
      rows=scope.offset((number-1)*per_page).limit(per_page).map { |row| block_given? ? yield(row) : row.as_json }
      {rows:rows,pagination:{page:number,per_page:per_page,total:total,pages:pages}}
    rescue ArgumentError,TypeError
      raise Error.new("invalid_page")
    end

    def self.page(rows, page: 1, per_page: 20)
      page = Integer(page.to_s, 10)
      per_page = Integer(per_page.to_s, 10)
      raise Error.new("invalid_page") unless page.positive? && per_page.between?(1, 100)
      pages = [(rows.size.to_f / per_page).ceil, 1].max
      page = [page, pages].min
      { rows: rows.slice((page - 1) * per_page, per_page) || [], pagination: { page: page, per_page: per_page, total: rows.size, pages: pages } }
    rescue ArgumentError, TypeError
      raise Error.new("invalid_page")
    end

    def self.trader(user_id, section: "positions", page: 1)
      user = User.find_by(id: user_id)
      raise Error.new("account_not_found", status: 404) unless Access.member?(user) && Account.wallet_snapshot(user_id).status == "active"
      scope = case section
      when "positions" then Position.where(user_id: user_id).includes(:instrument)
      when "orders" then Order.where(user_id: user_id).includes(:instrument)
      when "predictions" then Prediction.where(user_id: user_id).includes(:sport_match)
      else raise Error.new("invalid_section")
      end
      number = Integer(page.to_s, 10)
      raise Error.new("invalid_page") unless number.positive?
      total = scope.count
      pages = [(total.to_f / 20).ceil, 1].max
      number = [number, pages].min
      rows = scope.order(id: :desc).offset((number - 1) * 20).limit(20).map do |item|
        case section
        when "positions"
          Views.position(item).slice(:id,:symbol,:side,:quantity,:average,:margin,:leverage,:equity,:pnl,:valuation_basis,:valuation_at)
        when "orders"
          order = Views.order(item)
          order.slice(:id,:symbol,:side,:quantity,:status,:created_at,:leverage).merge(order[:details].symbolize_keys.slice(:price,:fee,:pnl,:payout,:gross,:reason))
        when "predictions"
          Views.prediction(item).merge(symbol: "#{item.sport_match.home} — #{item.sport_match.away}", side: item.pick, quantity: Amount.format(item.stake_units))
        end
      end
      { summary: portfolio(user_id).slice(:valuation_basis, :valuation_at, :user_id, :username, :forum_user, :equity, :total_pnl, :return_pct, :trade_count), section: section, rows: rows,
        pagination: { page: number, per_page: 20, total: total, pages: pages } }
    rescue ArgumentError, TypeError
      raise Error.new("invalid_page")
    end

    # Reconstruct only observed flow boundaries. The archive does not contain a
    # daily equity series, so no interpolated dates or post-cutover returns are added.
    def self.performance(user_id)
      period = LegacyRecord.where(source_table: "account_performance_periods")
        .where("data ->> 'discourse_user_id' = ? AND data ->> 'period_key' = 'all-time'", user_id.to_s).first&.data
      return { points: [], source: "legacy_flow_boundaries", complete: false } unless period
      flows = LegacyRecord.where(source_table: "account_performance_flows")
        .where("data ->> 'discourse_user_id' = ? AND data ->> 'period_key' = 'all-time'", user_id.to_s)
        .order(Arel.sql("data ->> 'created_at', (data ->> 'id')::bigint")).pluck(:data)
      opening = BigDecimal(period.fetch("opening_equity_rsc"))
      factor = BigDecimal("1")
      complete = opening.positive?
      points = [{ at: period["starts_at"], return_pct: complete ? "0" : nil }]
      flows.each do |flow|
        before = BigDecimal(flow.fetch("equity_before_rsc"))
        complete &&= opening.positive? && before >= 0
        factor *= before / opening if complete
        points << { at: flow["created_at"], return_pct: complete ? ((factor - 1) * 100).round(8).to_s("F") : nil }
        opening = before + BigDecimal(flow.fetch("signed_amount_rsc"))
      end
      { points: points, source: "legacy_flow_boundaries", complete: complete,
        archived_factor: period["twr_factor_scaled"], segment_opening_equity: period["segment_opening_equity_rsc"] }
    end

    def self.post_tips(post)
      tips_for_posts([post.id]).fetch(post.id, { total: "0", count: 0, tips: [] })
    end

    def self.tips_for_posts(post_ids)
      tips = Journal.where(operation: "post_tip").where("metadata ->> 'post_id' IN (?)", post_ids.map(&:to_s)).pluck(:actor_user_id, :metadata, :created_at).map do |id, data, at|
        { post_id: data["post_id"].to_i, user_id: id, amount: data.fetch("amount"), at: at }
      end
      LegacyRecord.where(source_table: "post_tips").where("data ->> 'post_id' IN (?)", post_ids.map(&:to_s)).pluck(:data).each do |data|
        tips << { post_id: data["post_id"].to_i, user_id: data.fetch("from_discourse_user_id").to_i, amount: data.fetch("amount_rsc"), at: Time.iso8601(data.fetch("created_at")) }
      end
      users = User.where(id: tips.map { |t| t[:user_id] }).index_by(&:id)
      tips.group_by { |t| t[:post_id] }.transform_values do |post_tips|
        grouped = post_tips.group_by { |t| t[:user_id] }.map do |id, items|
          username = users[id]&.username
          { forum_user: UserIdentity.serialize(users[id]), username: username || I18n.t("user.deleted"), user_url: username && "/u/#{ERB::Util.url_encode(username)}", amount: Amount.format(items.sum { |t| Amount.parse(t[:amount]) }), count: items.size, at: items.map { |t| t[:at] }.max }
        end.sort_by { |t| -t[:at].to_f }
        { total: Amount.format(post_tips.sum { |t| Amount.parse(t[:amount]) }), count: post_tips.size, tips: grouped }
      end
    end
  end
end
