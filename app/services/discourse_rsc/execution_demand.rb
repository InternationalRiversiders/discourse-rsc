# frozen_string_literal: true
module DiscourseRsc
  # One definition of live trading work, shared by polling, anomaly review and
  # backup-credit authorization. Every position needs liquidation monitoring;
  # stop settings are not a prerequisite for a valid risk price.
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
      when :execution then automatic?(id)
      when :forex_review then automatic?(id) || ForexReviewQueue.opening_review?(id)
      else false
      end
    end

    # Candidates may escalate a check, but are NEVER executable prices.
    # This avoids waiting on the routine timer when a quarantined move threatens
    # a stop or liquidation. The exchange still requires a verified fresh quote.
    def self.priority(instrument, purpose:)
      return :exit if purpose == :exit
      return :opening if purpose == :trade
      return :exit if orders.where(instrument_id: instrument.id, side: 'close').exists?
      held = positions.where(instrument_id: instrument.id).to_a
      prices = [instrument.quote['price'], instrument.quote.dig('verification', 'candidate', 'price')].filter_map do |value|
        Amount.positive(value) if value.present?
      rescue Error, ArgumentError, TypeError
        nil
      end
      return :urgent if held.any? && (prices.empty? || held.any? { |p| prices.any? { |price| Exchange.automatic_close_reason(p, price) } })
      # A frozen accepted price cannot indefinitely classify a holding as safe.
      # Candidate timestamps never reset this clock. Severe uncertainty uses
      # the same reserve as imminent risk; no stale price becomes executable.
      forex = instrument.category == 'forex'
      age = forex ? risk_quote_age(instrument.quote) : 0
      deadline = risk_review_after(held)
      return :urgent if held.any? && age >= deadline * 2
      return :opening if purpose == :forex_review && ForexReviewQueue.opening_review?(instrument.id)
      return :protection if held.any? { |p|
        (!forex && (p.take_profit_units || p.stop_loss_units)) || age >= deadline ||
          prices.any? { |price| near_exit?(p, price) }
      }
      return :opening if order?(instrument.id)
      :routine
    end

    def self.risk_review_after(held)
      leverage = held.map { |p| p.leverage.to_i }.max.to_i
      leverage >= 50 ? 360 : leverage >= 10 ? 600 : 900
    end

    def self.risk_quote_age(quote)
      times = %w[source_time received_at].map { |key| Time.iso8601(quote.fetch(key)) }
      return Float::INFINITY if times.any? { |at| at > 5.seconds.from_now }
      [Time.current - times.min, 0].max
    rescue KeyError, ArgumentError, TypeError
      Float::INFINITY
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
