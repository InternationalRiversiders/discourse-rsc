# frozen_string_literal: true
module DiscourseRsc
  class Administration
    def self.perform(actor:, action:, input:, request_id:)
      raise Error.new("admin_required", status: 403) unless Access.admin?(actor)
      raise Error.new("reason_required") unless input["reason"].is_a?(String) && input["reason"].strip.length.between?(1, 500)
      Commands.run(user_id: actor.id, action: "admin_#{action}", request_id: request_id, input: input) do
        Commands.lock("rsc-exchange")
        result = case action
        when "wallet_status"
          user = User.find(Integer(input.fetch("user_id")))
          status = input.fetch("status")
          raise Error.new("invalid_status") unless %w[active frozen].include?(status)
          raise Error.new("cannot_freeze_self") if user.id == actor.id && status == "frozen"
          wallet = Account.wallet(user.id)
          wallet.lock!
          before = wallet.status
          wallet.update!(status: status, status_reason: status == "frozen" ? input["reason"] : nil)
          Order.where(user_id: user.id, status: "pending").order(:instrument_id).each { |order| Exchange.send(:refund_locked, order, "canceled") } if status == "frozen"
          { user_id: user.id, before: before, status: status }
        when "reset_assets"
          user = User.find(Integer(input.fetch("user_id")))
          target = Amount.parse(input.fetch("amount"))
          mode = input.fetch("reset_mode", "cash")
          raise Error.new("invalid_admin_input") unless %w[cash total_equity].include?(mode)
          wallet = Account.wallet(user.id)
          wallet.lock!
          Order.where(user_id: user.id, status: "pending").each { |order| Exchange.send(:refund_locked, order, "canceled") }
          if input["clear_positions"] == true || input["clear_positions"] == "true"
            Position.where(user_id: user.id).order(:id).each do |position|
              margin = position.margin_units.to_i
              if margin.positive?
                Commands.move(user_id: actor.id, action: "admin_clear_position", request_id: "clear-#{request_id}-#{position.id}", settlement: true,
                              postings: { Account.internal("position:#{position.id}").id => -margin, Account.internal("system:exchange", kind: "system").id => margin }, metadata: { position_id: position.id, reason: input["reason"] })
              end
              position.destroy!
            end
          end
          wallet.reload
          before = wallet.balance
          retained = Position.where(user_id: user.id).includes(:instrument).sum do |position|
            position.margin_units.to_i + Valuation.position(position)[:pnl]
          end + Prediction.where(user_id: user.id, status: "pending").sum(:stake_units).to_i +
            ForecastPosition.where(user_id: user.id, state: "open").sum(:cost_units).to_i
          raise Error.new("reset_below_retained", status: 409) if mode == "total_equity" && target < retained
          balance_target = mode == "cash" ? target : target - retained
          delta = balance_target - wallet.balance_units.to_i
          # Explicit administrative adjustment may debit a frozen wallet; temporarily
          # unlock only inside this transaction, restoring the original status.
          status = wallet.status
          wallet.update!(status: "active")
          unless delta.zero?
            Commands.move(user_id: actor.id, action: "admin_adjustment", request_id: request_id,
                          postings: { wallet.id => delta, Account.issuance.id => -delta }, metadata: { recipient_user_id: user.id, amount: Amount.format(delta), reason: input["reason"] })
          end
          wallet.update!(status: status)
          { user_id: user.id, before: before, balance: Amount.format(balance_target), reset_mode: mode, target: Amount.format(target), retained_assets: Amount.format(retained) }
        when "exemption"
          user = User.find(Integer(input.fetch("user_id")))
          expires = Time.iso8601(input.fetch("expires_at"))
          raise Error.new("invalid_expiry") unless expires > Time.current && expires <= 366.days.from_now
          starts = input["starts_at"].present? ? Time.iso8601(input["starts_at"]) : Time.current
          raise Error.new("invalid_expiry") unless starts < expires
          exemption = Exemption.create!(user_id: user.id, starts_at: starts, expires_at: expires, reason: input["reason"], actor_user_id: actor.id)
          { exemption_id: exemption.id }
        when "instrument"
          symbol = MarketData.symbol(input.fetch("symbol"))
          provider = input.fetch("provider", "yahoo")
          category = input.fetch("category", "us")
          raise Error.new("invalid_provider") unless %w[yahoo coinbase twelve_data kraken okx manual].include?(provider)
          raise Error.new("invalid_category") unless MarketData::CATEGORIES.include?(category)
          raise Error.new('market_opening_disabled') if %w[ca in au].include?(category) && input['active'].to_s != 'false'
          instrument = Instrument.lock.find_or_initialize_by(symbol: symbol)
          if instrument.persisted? && (Position.exists?(instrument_id: instrument.id) || Order.exists?(instrument_id: instrument.id, status: "pending"))
            raise Error.new("instrument_has_positions", status: 409) if provider != instrument.provider || category != instrument.category || input["active"].to_s == "false"
          end
          instrument.update!(name: input.fetch("name", symbol).to_s.first(100), provider: provider, provider_symbol: MarketData.symbol(input.fetch("provider_symbol", symbol)),
                             category: category, asset_type: input.fetch("asset_type", instrument.asset_type.presence || (category == "crypto" ? "crypto" : "stock")).to_s.first(30), currency: input.fetch("currency", "USD"), active: input["active"].to_s != "false",
                             fee_bps: Integer(input.fetch("fee_bps", 5)), minimum_units: Amount.positive(input.fetch("minimum", "1")), step_units: Amount.positive(input.fetch("step", "1")))
          MarketRequest.where(symbol: symbol, status: "pending").update_all(status: "approved", updated_at: Time.current)
          { instrument_id: instrument.id }
        when "manual_quote"
          instrument = Instrument.lock.find(Integer(input.fetch("id")))
          raise Error.new("invalid_provider") unless instrument.provider == "manual"
          starts, ends = Time.iso8601(input.fetch("session_start")), Time.iso8601(input.fetch("session_end"))
          raise Error.new("invalid_session") unless ends > starts && ends - starts <= 24.hours
          price = Amount.format(Amount.positive(input.fetch("price")))
          quote = { "price" => price, "previous_close" => Amount.format(Amount.positive(input.fetch("previous_close"))), "source" => "manual",
                    "source_time" => Time.current.iso8601(6), "received_at" => Time.current.iso8601(6), "delay_seconds" => 0,
                    "session_start" => starts.iso8601, "session_end" => ends.iso8601 }
          instrument.update!(quote: quote, history: (instrument.history + [{ at: Time.current.iso8601(6), price: price }]).last(1440))
          { instrument_id: instrument.id }
        when "seed_catalog"
          { created: Catalog.seed }
        when "reject_request"
          request = MarketRequest.lock.find(Integer(input.fetch("id")))
          request.update!(status: "rejected")
          { id: request.id }
        when "match_result"
          match = SportMatch.lock.find(Integer(input.fetch("id")))
          result = input.fetch("result")
          raise Error.new("invalid_pick") unless %w[home away draw canceled].include?(result) && (result != "draw" || match.allow_draw)
          raise Error.new("prediction_settled", status: 409) if match.predictions.where.not(status: "pending").exists?
          match.update!(status: result == "canceled" ? "canceled" : "finished", result: result == "canceled" ? nil : result, confirmed_at: Time.current, provider_data: match.provider_data.merge("manual_result" => true))
          { match_id: match.id }
        else
          raise Error.new("invalid_admin_action")
        end
        Audit.create!(actor_user_id: actor.id, action: action, details: { input: input, result: result }, created_at: Time.current)
        result
      end
    rescue ArgumentError, KeyError
      raise Error.new("invalid_admin_input")
    end
  end
end
