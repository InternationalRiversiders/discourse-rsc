# frozen_string_literal: true
module DiscourseRsc
  # Holdings remain polling work, but are not FX backup-credit demand.
  # Explicit orders and bounded submission reviews may still use the backup.
  module ExecutionDemand
    def self.wallet_users
      Account.where(kind: 'wallet', status: 'active').select(:user_id)
    end

    def self.positions
      Position.where(user_id: wallet_users).where('quantity_units > 0')
    end

    def self.orders
      live = Order.where(user_id: wallet_users, status: 'pending').where('expires_at > ?', Time.current)
      # Delayed stocks can fill as soon as a post-order observation arrives;
      # crypto also uses the current valid quote, including legacy pending orders.
      live.where('execute_at <= ?', Time.current)
        .or(live.where("details->>'delayed' = 'true'"))
        .or(live.where(instrument_id: Instrument.where(category: 'crypto').select(:id)))
    end

    def self.order?(id)
      orders.where(instrument_id: id).exists?
    end

    def self.automatic?(id)
      positions.where(instrument_id: id).exists? || order?(id)
    end

    def self.instrument_ids
      positions.distinct.pluck(:instrument_id) | orders.distinct.pluck(:instrument_id)
    end

    def self.allowed?(id, purpose:)
      case purpose
      when :trade, :exit then true
      when :execution then backup_demand?(id)
      when :forex_review then backup_demand?(id) || ForexReviewQueue.opening_review?(id)
      else false
      end
    end

    # Autonomous FX protection is primary-only. Explicit queued orders still
    # represent a user's trading request and may use the backup when necessary.
    def self.backup_demand?(id)
      order?(id) || (Instrument.where(id: id).where.not(category: 'forex').exists? && automatic?(id))
    end

    # Candidates may prioritize primary polling, but are NEVER executable.
    # Priority alone does not grant backup access; allowed? is the separate gate.
    def self.priority(instrument, purpose:)
      return :exit if purpose == :exit
      return :opening if purpose == :trade
      return :exit if orders.where(instrument_id: instrument.id, side: 'close').exists?
      if instrument.category == 'forex' && (order?(instrument.id) || (purpose == :forex_review && ForexReviewQueue.opening_review?(instrument.id)))
        return :opening
      end
      held = positions.where(instrument_id: instrument.id).to_a
      quote = instrument.category == 'forex' ? ForexQuoteGuard.automatic_quote(instrument.quote) : instrument.quote
      prices = [quote['price'], quote.dig('verification', 'candidate', 'price')].filter_map do |value|
        Amount.positive(value) if value.present?
      rescue Error, ArgumentError, TypeError
        nil
      end
      return :urgent if held.any? && (prices.empty? || held.any? { |p| prices.any? { |price| Exchange.automatic_close_reason(p, price) } })
      forex = instrument.category == 'forex'
      return :opening if purpose == :forex_review && ForexReviewQueue.opening_review?(instrument.id)
      return :protection if held.any? { |p|
        (!forex && (p.take_profit_units || p.stop_loss_units)) ||
          prices.any? { |price| near_exit?(p, price) }
      }
      return :opening if order?(instrument.id)
      :routine
    end

    def self.rank(instrument)
      {exit: 0, urgent: 0, protection: 1, opening: 2, routine: 3}.fetch(priority(instrument, purpose: :execution))
    end

    def self.sort_key(instrument)
      last = Discourse.redis.get("rsc:fallback-routine-symbol:#{instrument.id}").to_s.split(':').first.to_f
      [rank(instrument), last, instrument.synced_at || Time.at(0)]
    end

    def self.near_exit?(position, price)
      # Half of the posted margin remains: liquidation is at one quarter.
      return true if position.margin_units.to_i + Exchange.pnl(position, price) <= position.margin_units.to_i / 2
      long = position.side == 'long'
      tolerance = price * 20 / 10_000 # 0.2% proximity, not a changed trigger price.
      sl = position.stop_loss_units
      tp = position.take_profit_units
      (sl && (long ? price <= sl + tolerance : price >= sl - tolerance)) ||
        (tp && (long ? price >= tp - tolerance : price <= tp + tolerance))
    end

    def self.operation(id, purpose:)
      case purpose
      when :trade then 'open_order'
      when :exit then 'close_order'
      when :execution then order?(id) ? 'pending_order' : 'position_risk'
      when :forex_review then order?(id) ? 'pending_order_review' : positions.where(instrument_id: id).exists? ? 'position_risk_review' : 'opening_review'
      else 'non_trading'
      end
    end
  end
end
