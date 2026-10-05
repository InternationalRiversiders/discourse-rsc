# frozen_string_literal: true
module DiscourseRsc
  class DashboardController < WalletController
    skip_before_action :ensure_rsc_member, only: [:index]
    before_action :ensure_native_trial, except: [:index]

    def index
      Access.ensure_member!(current_user) unless Access.admin?(current_user)
      render "default/empty"
    end

    def state
      section = params[:section].to_s
      raise Error.new('invalid_request') unless ['', 'wallet', 'market', 'sports', 'packet'].include?(section)
      full = section.empty? # Compatibility for existing clients during an A/B switch.
      market = full || section == 'market'
      sports = full || section == 'sports'
      wallet_page = full || section == 'wallet'
      wallet = Account.wallet_snapshot(current_user.id)
      positions = market ? Position.where(user_id: current_user.id).includes(:instrument).order(:id).map { |p| Views.position(p) } : []
      margin = positions.sum { |p| Amount.parse(p[:margin]) }
      profits = positions.map { |p| p[:pnl] && BigDecimal(p[:pnl]) }
      pnl = profits.none?(&:nil?) ? (profits.sum * Amount::UNIT).to_i : nil
      reserved = Order.where(user_id: current_user.id, status: 'pending').sum(:reserved_units)
      orders = market ? Order.where(user_id: current_user.id).includes(:instrument).order(id: :desc).limit(50).to_a : []
      focused = Order.where(user_id: current_user.id).includes(:instrument).find_by(id: positive_id(:order_id)) if market && params[:order_id].present?
      orders.unshift(focused) if focused && orders.none? { |o| o.id == focused.id }
      listing = MarketListing.page(params) if section == 'market'
      instruments = full ? MarketListing.rows(Instrument.where(active: true).order(:symbol).to_a) : []
      if listing
        # Keep selected/held instruments available even outside the current results page.
        ids = positions.map { |p| p[:instrument_id] }
        ids << positive_id(:instrument_id) if params[:instrument_id].present?
        ids << focused.instrument_id if focused
        selected = MarketListing.rows(Instrument.where(id: ids.uniq).to_a)
        instruments = (selected + listing[:rows]).uniq { |row| row[:id] }
      end
      entries = wallet_page ? Entry.where(account_id: wallet.id).includes(:journal).order(id: :desc).limit(30) : []
      team_names = SportsTeamTranslation.names if sports
      predictions = sports ? Prediction.where(user_id: current_user.id).includes(:sport_match).order(id: :desc).limit(100) : []
      render_json_dump(
        market_data_enabled: SiteSetting.rsc_market_data_enabled,
        high_risk: market ? Risk.high_risk_status(current_user.id) : { positions: [], pending: [] },
        read_only: Safety.read_only?, reward: wallet_page ? Rewards.today(current_user.id) : {},
        demo: instruments.present? && instruments.all? { |item| item[:quote]['demo'] },
        admin: Access.admin?(current_user), high_risk_enabled: SiteSetting.rsc_high_risk_enabled,
        trial: true, odds_max_age_hours: SiteSetting.rsc_odds_max_age_hours,
        wallet: { balance: wallet.balance, status: wallet.status, status_reason: wallet.status_reason, reserved: Amount.format(reserved) },
        instruments: instruments, market_page: listing, positions: positions,
        portfolio: { notional: Amount.format(positions.sum { |p| Amount.parse(p[:quantity]) * Amount.parse(p[:average]) / Amount::UNIT }),
          reserved: Amount.format(reserved), margin: Amount.format(margin), pnl: pnl && Amount.format(pnl), equity: pnl && Amount.format(margin + pnl) },
        orders: orders.map { |item| Views.order(item) },
        matches: sports ? Views.matches(current_user.id, focus: params[:match_id].present? ? positive_id(:match_id) : nil) : [],
        predictions: predictions.map { |item| Views.prediction(item, names: team_names) },
        packets: wallet_page ? Packet.where(user_id: current_user.id).includes(:claims).order(id: :desc).limit(30).map { |item| packet_json(item) } : [],
        entries: entries.map { |item| { id: item.id, operation: item.journal.operation, amount: Amount.format(item.units), balance: Amount.format(item.balance_after_units), created_at: item.created_at } },
      )
    end

    def order
      RateLimiter.new(current_user, "rsc-orders", 30, 1.minute).performed!
      result = Exchange.submit(actor: current_user, instrument_id: positive_id(:instrument_id), side: params.require(:side),
                               quantity: params.require(:quantity), leverage: positive_id(:leverage), request_id: params.require(:request_id), high_risk: params[:high_risk].to_s == "true", take_profit: params[:take_profit], stop_loss: params[:stop_loss])
      render_json_dump(result)
    rescue Error => error
      # Legacy exchange_order_rejections recorded failed attempts separately from
      # executed orders. Keep that diagnostic trail without creating a trade or
      # changing the original error returned to the member.
      begin
        Audit.create!(actor_user_id: current_user.id, action: "order_rejected", created_at: Time.current,
          details: params.permit(:instrument_id, :side, :quantity, :leverage, :request_id).to_h.transform_values { |value| value.to_s.first(100) }.merge("error" => error.code))
      rescue ActiveRecord::ActiveRecordError => audit_error
        Rails.logger.warn("RSC rejected-order audit failed: #{audit_error.class}")
      end
      raise
    end

    def cancel_order
      render_json_dump(Exchange.cancel(actor: current_user, order_id: positive_id(:id), request_id: params.require(:request_id)))
    end

    def protect
      render_json_dump(Exchange.protect(actor: current_user, position_id: positive_id(:id), take_profit: params[:take_profit],
                                       stop_loss: params[:stop_loss], request_id: params.require(:request_id)))
    end

    def predict
      render_json_dump(Sports.predict(actor: current_user, match_id: positive_id(:match_id), pick: params.require(:pick),
                                      stake: params.require(:stake), request_id: params.require(:request_id),
                                      prediction_id: params[:prediction_id].present? ? positive_id(:prediction_id) : nil))
    end

    def create_packet
      render_json_dump(RedPackets.create(actor: current_user, mode: params.require(:mode), count: positive_id(:count),
                                         amount: params.require(:amount), minimum: params[:minimum] || "0.01", maximum: params[:maximum].presence,
                                         days: params[:days].present? ? positive_id(:days) : 1, message: params[:message] || "", request_id: params.require(:request_id)))
    end

    def packet
      item = Packet.find_by!(token: params.require(:token))
      render_json_dump(packet_json(item).merge(claimed: item.claims.exists?(user_id: current_user.id), own: item.user_id == current_user.id, claims: item.claims.order(:id).map { |claim| { forum_user: UserIdentity.serialize(claim.user_id), username: User.find_by(id: claim.user_id)&.username, amount: Amount.format(claim.units), at: claim.created_at } }))
    end

    def packets
      section = params.fetch(:section,"sent")
      raise Error.new("invalid_section") unless %w[sent received].include?(section)
      scope = section == "sent" ? Packet.where(user_id:current_user.id) : Packet.where(id:PacketClaim.where(user_id:current_user.id).select(:packet_id))
      render_json_dump(Reports.relation_page(scope.includes(:claims).order(id: :desc),page:params.fetch(:page,1),per_page:20) { |item| Views.packet(item,current_user.id) })
    end

    def claim_packet
      render_json_dump(RedPackets.claim(actor: current_user, token: params.require(:token), request_id: params.require(:request_id)))
    end

    def close_packet
      render_json_dump(RedPackets.close(actor: current_user, token: params.require(:token), request_id: params.require(:request_id)))
    end

    private

    def ensure_native_trial
      raise Error.new("trial_disabled", status: 403) unless SiteSetting.rsc_native_trial_enabled
    end

    def packet_json(item)
      Views.packet(item,current_user.id)
    end
  end
end
