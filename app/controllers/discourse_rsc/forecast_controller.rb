# frozen_string_literal: true
module DiscourseRsc
  class ForecastController < WalletController
    skip_before_action :ensure_rsc_member, only: %i[requests review_listing auto_review_settings]
    before_action :ensure_forecast
    def index
      render 'default/empty'
    end

    def state
      wallet = Account.wallet_snapshot(current_user.id)
      scope = ForecastMarket.where(featured: true).where.not(state: 'resolved').order(volume: :desc)
      holdings = ForecastPosition.where(user_id: current_user.id).where('shares_units > 0').includes(:market).order(updated_at: :desc)
      trades = ForecastTrade.where(user_id: current_user.id).includes(:market).order(id: :desc).limit(30)
      metadata = ForecastDiscovery.metadata
      markets = scope.reject { |m| ForecastDiscovery.excluded?(question: m.question, event_title: m.event_title, rules: m.rules) }
      markets.sort_by! { |m| metadata.dig(m.id.to_s, 'rank') || ForecastDiscovery::LIMIT + 1 }
      joined = ForecastMarket.where(id: ForecastRequest.approved_markets).where.not(state: 'resolved').order(id: :desc)
      render_json_dump(admin: Access.admin?(current_user), joined: joined.limit(200).reject { |m| ForecastDiscovery.excluded?(question: m.question, event_title: m.event_title, rules: m.rules) }.map { |m| market_view(m) }, markets: markets.first(ForecastDiscovery::LIMIT).map { |m| market_view(m).merge(category: metadata.dig(m.id.to_s, 'category') || 'other') }, balance: wallet.balance,
        read_only: Safety.read_only?, holdings: holdings.limit(100).map { |p| position_view(p) },
        trades: trades.map { |t| { id: t.id, market_id: t.market_id, question: ForecastTranslation.presentation(t.market)[:question], outcome: ForecastTranslation.presentation(t.market)[:outcomes][t.outcome],
          side: t.side, outcome_index: t.outcome, shares: Amount.format(t.shares_units), cash: Amount.format(t.cash_units), pnl: Amount.format(t.pnl_units), at: t.created_at } })
    end

    def catalog
      RateLimiter.new(current_user, 'rsc-forecast-catalog', 20, 1.minute).performed!
      render_json_dump(ForecastCatalog.browse(actor: current_user, query: params[:q], category: params.fetch(:category, 'all'), order: params.fetch(:order, 'balanced'), page: params[:page], event_id: params[:event_id]))
    end

    def catalog_show
      RateLimiter.new(current_user, 'rsc-forecast-preview', 15, 1.minute).performed!
      external_id = ForecastCatalog.id(params[:external_id])
      raw = ForecastCatalog.preview(external_id)
      existing = ForecastMarket.find_by(external_id: external_id)
      market = existing || ForecastMarket.new(ForecastProvider.parse(raw))
      market.synced_at = Time.iso8601(raw['_rsc_fetched_at']) if !existing && raw['_rsc_fetched_at']
      own_request = ForecastRequest.find_by(user_id: current_user.id, external_id: external_id)
      render_json_dump(market_view(market, detail: true).merge(preview: true, external_id: external_id,
        market_id: existing&.id, request_status: own_request&.status, review_reason: own_request&.review_reason))
    end

    def requests
      raise Error.new('membership_required', status: 403) unless Access.member?(current_user) || Access.admin?(current_user)
      own = ForecastRequest.where(user_id: current_user.id).order(id: :desc).limit(50)
      data = { mine: own.map { |r| request_view(r) } }
      if params[:admin] == 'true'
        raise Error.new('admin_required', status: 403) unless Access.admin?(current_user)
        data[:pending] = ForecastRequest.where(status: 'pending').order(:id).limit(100).map { |r| request_view(r) }
        data[:auto_review_enabled] = SiteSetting.rsc_forecast_auto_review_enabled
        data[:auto_review_configured] = !!ForecastAutoReview.configured?
      end
      render_json_dump(data)
    end

    def request_listing
      RateLimiter.new(current_user, 'rsc-forecast-request', 5, 1.hour).performed!
      render_json_dump(ForecastListing.submit(actor: current_user, external_id: params.require(:external_id), reason: params[:reason], request_id: params.require(:request_id)))
    end

    def review_listing
      RateLimiter.new(current_user, 'rsc-forecast-review', 10, 1.minute).performed!
      render_json_dump(ForecastListing.review(actor: current_user, external_id: params.require(:external_id), decision: params.require(:decision), reason: params[:reason], request_id: params.require(:request_id)))
    end

    def auto_review_settings
      raise Error.new('admin_required', status: 403) unless Access.admin?(current_user)
      value = params.require(:enabled).to_s
      raise Discourse::InvalidParameters.new(:enabled) unless %w[true false].include?(value)
      raise Error.new('forecast_ai_unconfigured') if value == 'true' && !ForecastAutoReview.configured?
      SiteSetting.rsc_forecast_auto_review_enabled = value == 'true'
      Audit.create!(actor_user_id: current_user.id, action: 'forecast_auto_review_settings',
        details: { enabled: value == 'true' }, created_at: Time.current)
      render_json_dump(auto_review_enabled: SiteSetting.rsc_forecast_auto_review_enabled)
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
    def request_view(row)
      { id: row.id, external_id: row.external_id, question: row.question, status: row.status,
        reason: row.reason, review_reason: row.review_reason, market_id: row.market_id, created_at: row.created_at,
        auto_review: ForecastAutoReview.presentation(row) }
    end

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
