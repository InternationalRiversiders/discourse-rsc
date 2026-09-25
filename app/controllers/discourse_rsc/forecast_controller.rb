# frozen_string_literal: true
module DiscourseRsc
  class ForecastController < WalletController
    before_action :ensure_forecast
    def index
      render 'default/empty'
    end

    def state
      wallet = Account.wallet_snapshot(current_user.id)
      scope = ForecastMarket.where(featured: true).where.not(state: 'resolved').order(volume: :desc)
      holdings = ForecastPosition.where(user_id: current_user.id).where('shares_units > 0').includes(:market).order(updated_at: :desc)
      trades = ForecastTrade.where(user_id: current_user.id).includes(:market).order(id: :desc).limit(30)
      render_json_dump(markets: scope.limit(24).map { |m| market_view(m) }, balance: wallet.balance,
        read_only: Safety.read_only?, holdings: holdings.limit(100).map { |p| position_view(p) },
        trades: trades.map { |t| { id: t.id, market_id: t.market_id, question: ForecastTranslation.presentation(t.market)[:question], outcome: ForecastTranslation.presentation(t.market)[:outcomes][t.outcome],
          side: t.side, outcome_index: t.outcome, shares: Amount.format(t.shares_units), cash: Amount.format(t.cash_units), pnl: Amount.format(t.pnl_units), at: t.created_at } })
    end

    def show
      render_json_dump(market_view(ForecastMarket.find(positive_id(:id)), detail: true))
    end

    def history
      RateLimiter.new(current_user, 'rsc-forecast-history', 20, 1.minute).performed!
      interval = params.fetch(:interval, '1w')
      raise Error.new('invalid_section') unless %w[1d 1w 1m max].include?(interval)
      render_json_dump(points: ForecastProvider.history(ForecastMarket.find(positive_id(:id)), outcome, interval))
    end

    def quote
      RateLimiter.new(current_user, 'rsc-forecast-quote', 6, 1.minute).performed!
      render_json_dump(ForecastExchange.quote(actor: current_user, market_id: positive_id(:id), outcome: outcome,
        side: params.require(:side), amount: params.require(:amount)))
    end

    def trade
      RateLimiter.new(current_user, 'rsc-forecast-trade', 10, 1.minute).performed!
      render_json_dump(ForecastExchange.execute(actor: current_user, token: params.require(:token), request_id: params.require(:request_id)))
    end

    private
    def ensure_forecast
      ForecastExchange.enabled!
    end

    def outcome
      value = params.fetch(:outcome, '0').to_s
      raise Error.new('invalid_pick') unless %w[0 1].include?(value)
      value.to_i
    end

    def market_view(m, detail: false)
      localized = ForecastTranslation.presentation(m)
      view = { id: m.id, question: localized[:question], event_title: localized[:event_title], outcomes: localized[:outcomes], prices: m.prices,
        translated: localized[:translated], original_question: m.question,
        volume: m.volume.to_s('F'), liquidity: m.liquidity.to_s('F'), ends_at: m.ends_at, state: m.state,
        synced_at: m.synced_at, confirmed_at: m.confirmed_at, settled_at: m.settled_at,
        payouts: ForecastSettlement.payouts(m.resolution), resolution_status: m.resolution['status'],
        url: "https://polymarket.com/market/#{m.slug}" }
      if detail
        view[:rules] = localized[:rules]
        view[:original_rules] = m.rules
        view[:original_outcomes] = m.outcomes
      end
      view
    end

    def position_view(p)
      { id: p.id, market_id: p.market_id, question: ForecastTranslation.presentation(p.market)[:question], outcome: p.outcome, label: ForecastTranslation.presentation(p.market)[:outcomes][p.outcome],
        shares: Amount.format(p.shares_units), cost: Amount.format(p.cost_units), realized: Amount.format(p.realized_units),
        state: p.state, market_state: p.market.state }
    end
  end
end
