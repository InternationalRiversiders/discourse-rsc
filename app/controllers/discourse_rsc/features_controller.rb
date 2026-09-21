# frozen_string_literal: true
module DiscourseRsc
  class FeaturesController < DashboardController
    skip_before_action :ensure_logged_in, only: %i[tips topic_tips]
    skip_before_action :ensure_rsc_member, only: %i[tips topic_tips admin_state admin_action sync rewards reward_preview campaign campaign_apply admin_activity search_demand market_lookup market_approve settle]
    before_action :ensure_admin, only: %i[admin_state admin_action sync rewards reward_preview campaign campaign_apply admin_activity search_demand market_lookup market_approve settle]
    def history
      RateLimiter.new(current_user, "rsc-history", 30, 1.minute).performed!
      render_json_dump(MarketData.history(Instrument.find(positive_id(:id)), params.fetch(:range, "1d")))
    end
    def refresh_quote
      RateLimiter.new(current_user, "rsc-quote-refresh", 30, 1.minute).performed!
      item = MarketData.refresh_if_needed(positive_id(:id))
      render_json_dump(instrument: MarketListing.rows([item]).first)
    end
    def search
      RateLimiter.new(current_user, "rsc-search", 12, 1.minute).performed!
      raise Error.new("provider_disabled", status: 503) unless SiteSetting.rsc_market_data_enabled
      candidates = MarketData.search(params[:q])
      Search.create!(user_id: current_user.id, query: params[:q].strip, result_count: candidates.size, created_at: Time.current) if request.post?
      render_json_dump(candidates: candidates)
    end
    def record_search
      RateLimiter.new(current_user, 'rsc-local-search', 30, 1.minute).performed!
      query = params.require(:q).to_s.strip.gsub(/\s+/, ' ').first(80)
      raise Error.new('invalid_search') unless query.length >= 2
      count = Integer(params.require(:result_count).to_s, 10)
      raise Error.new('invalid_search') unless count.between?(0, 10000)
      Search.create!(user_id: current_user.id, query: query, result_count: count, created_at: Time.current)
      render_json_dump(success: true)
    rescue ArgumentError
      raise Error.new('invalid_search')
    end

    def market_request
      RateLimiter.new(current_user, "rsc-market-request", 10, 1.day).performed!
      symbol = MarketData.symbol(params.require(:symbol))
      request = MarketRequest.find_or_create_by!(user_id: current_user.id, symbol: symbol)
      request.with_lock do
        listed = Instrument.where(active: true).where('symbol = ? OR provider_symbol = ?', symbol, symbol).exists?
        request.update!(status: listed ? 'approved' : 'pending', details: request.details.merge('request_count' => request.details.fetch('request_count', 0).to_i + 1))
      end
      render_json_dump(id: request.id, status: request.status)
    end
    def admin_activity
      render_json_dump(AdminReports.activity(kind: params.fetch(:kind, 'all'), query: params[:q], status: params.fetch(:status, 'all'), topic_id: params[:topic_id], page: params.fetch(:page, 1)))
    end
    def search_demand
      render_json_dump(AdminReports.search_demand(page: params.fetch(:page, 1)))
    end
    def market_lookup
      RateLimiter.new(current_user, 'rsc-admin-lookup', 12, 1.minute).performed!
      raise Error.new('provider_disabled', status: 503) unless SiteSetting.rsc_market_data_enabled
      render_json_dump(candidates: MarketData.search(params[:q]))
    end
    def market_approve
      RateLimiter.new(current_user, 'rsc-admin-approve', 12, 1.minute).performed!
      render_json_dump(Catalog.approve(actor: current_user, symbol: params.require(:symbol), reason: params.require(:reason), request_id: params.require(:request_id)))
    end
    def settle
      result = Sports.settle_pending
      Audit.create!(actor_user_id: current_user.id, action: 'manual_settlement', details: result, created_at: Time.current)
      render_json_dump(result)
    end
    def leaderboard
      rows=Reports.leaderboard(params.fetch(:sort, "equity"))
      query=params[:q].to_s.strip.downcase.first(60)
      rows=rows.select { |r| r[:username].to_s.downcase.include?(query) } if query.present?
      render_json_dump(Reports.page(rows, page: params.fetch(:page, 1), per_page: params.fetch(:per_page, 20)))
    end
    def trader
      result = Reports.trader(positive_id(:id), section: params.fetch(:section, "positions"), page: params.fetch(:page, 1))
      result[:performance] = Reports.performance(positive_id(:id)) if params.fetch(:page, "1").to_s == "1"
      render_json_dump(result)
    end
    def portfolio
      render_json_dump(Reports.portfolio(current_user.id))
    end
    def margin
      render_json_dump(Exchange.add_margin(actor: current_user, position_id: positive_id(:id), amount: params.require(:amount), request_id: params.require(:request_id)))
    end
    def legacy_entries
      records = LegacyRecord.where(source_table: "ledger_entries").where("data ->> 'discourse_user_id' = ?", current_user.id.to_s).order(id: :desc).limit(50)
      records = records.where("id < ?", positive_id(:before)) if params[:before].present?
      render_json_dump(entries: records.map { |record| record.data.slice("type", "direction", "amount_rsc", "balance_after", "created_at").merge("id" => record.id, "balance_after" => record.data["balance_after"]) })
    end
    def tips
      post = Post.find(positive_id(:id))
      guardian.ensure_can_see!(post)
      raise Error.new("invalid_post", status: 404) if post.deleted_at || post.hidden || !post.topic.regular?
      render_json_dump(Reports.post_tips(post))
    end
    def topic_tips
      topic = Topic.find(positive_id(:id))
      guardian.ensure_can_see!(topic)
      raise Error.new("invalid_post", status: 404) if topic.deleted_at || !topic.regular?
      ids = params.require(:post_ids).to_s.split(",")
      raise Discourse::InvalidParameters.new(:post_ids) unless ids.size.between?(1, 100) && ids.all? { |id| /\A[1-9][0-9]{0,18}\z/.match?(id) }
      posts = topic.posts.where(id: ids.map(&:to_i), deleted_at: nil, hidden: false, post_type: Post.types[:regular]).to_a.select { |post| guardian.can_see?(post) }
      render_json_dump(posts: Reports.tips_for_posts(posts.map(&:id)))
    end
    def admin_state
      query=params[:q].to_s.strip.downcase.first(60)
      users=User.order(:id)
      users= /\A[1-9][0-9]*\z/.match?(query) ? users.where(id:query.to_i) : users.where("username_lower LIKE ?","%#{User.sanitize_sql_like(query)}%") if query.present?
      wallet_page=Reports.relation_page(users,page:params.fetch(:wallet_page,1),per_page:20) do |user|
        wallet=Account.find_by(user_id:user.id,kind:"wallet")
        {id:user.id,username:user.username,balance:wallet&.balance || "0",status:wallet&.status || "active",status_reason:wallet&.status_reason}
      end
      search=params[:instrument_q].to_s.strip.first(80)
      category = params[:instrument_category].presence
      raise Error.new('invalid_category') if category && !MarketData::CATEGORIES.include?(category)
      instruments=Instrument.order(:symbol)
      instruments=instruments.where(category: category) if category
      instruments=instruments.where("symbol ILIKE :q OR name ILIKE :q",q:"%#{Instrument.sanitize_sql_like(search)}%") if search.present?
      instrument_page=Reports.relation_page(instruments,page:params.fetch(:instrument_page,1)) { |i| {id:i.id,symbol:i.symbol,name:i.name,asset_type:i.asset_type,provider:i.provider,active:i.active,error:i.provider_error,synced_at:i.synced_at} }
      funds=Reports.relation_page(Journal.order(id: :desc),page:params.fetch(:fund_page,1)) { |j| {id:j.id,actor_user_id:j.actor_user_id,operation:j.operation,metadata:j.metadata,created_at:j.created_at} }
      audits=Reports.relation_page(Audit.order(id: :desc),page:params.fetch(:audit_page,1))
      requests=Reports.relation_page(MarketRequest.order(id: :desc),page:params.fetch(:request_page,1))
      render_json_dump(
        wallets:wallet_page[:rows],instruments:instrument_page[:rows],funds:funds[:rows],audits:audits[:rows],requests:requests[:rows],
        pagination:{wallet:wallet_page[:pagination],instrument:instrument_page[:pagination],fund:funds[:pagination],audit:audits[:pagination],request:requests[:pagination]},
        events: Event.where(delivered_at: nil).order(:id).limit(30).map { |e| e.attributes.slice("id", "kind", "attempts", "last_error", "next_attempt_at") },
        market_health: MarketData.health,
        read_only: Safety.read_only?,
        stats: { wallets: Account.where(kind: "wallet").count, circulating: Amount.format(Account.where(kind: "wallet").sum(:balance_units)), escrow: Amount.format(Account.where(kind: "escrow").sum(:balance_units)), journals: Journal.count },
        matches: SportMatch.where(status: %w[finished canceled]).order(starts_at: :desc).limit(30).as_json,
      )
    end
    def admin_action
      render_json_dump(Administration.perform(actor: current_user, action: params.require(:operation), input: params.require(:input).permit(:user_id, :status, :reason, :amount, :reset_mode, :clear_positions, :starts_at, :expires_at, :symbol, :provider, :provider_symbol, :category, :asset_type, :currency, :name, :active, :fee_bps, :minimum, :step, :id, :result, :price, :previous_close, :session_start, :session_end).to_h, request_id: params.require(:request_id)))
    end
    def sync
      RateLimiter.new(current_user, "rsc-admin-sync", 1, 1.minute).performed!
      Jobs.enqueue(:discourse_rsc_manual_sync, actor_user_id: current_user.id)
      render_json_dump(queued: true)
    end
    def campaign
      render_json_dump(Campaign.preview)
    end
    def campaign_apply
      render_json_dump(Campaign.apply(actor: current_user))
    end
    def reward_preview
      render_json_dump(rows: Rewards.preview(params.require(:date)))
    end

    def rewards
      date = params.require(:date)
      if params[:pay].to_s == "true"
        Rewards.pay(date)
        Audit.create!(actor_user_id: current_user.id, action: "rewards_payout", details: { date: date }, created_at: Time.current)
      end
      render_json_dump(rows: Rewards.preview(date))
    end
    private
    def ensure_admin
      raise Error.new("admin_required", status: 403) unless Access.admin?(current_user)
    end
  end
end
