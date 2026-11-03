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
      when :execution, :forex_review then automatic?(id)
      else false
      end
    end

    def self.operation(id, purpose:)
      case purpose
      when :trade then 'open_order'
      when :exit then 'close_order'
      when :execution then order?(id) ? 'pending_order' : 'position_risk'
      when :forex_review then order?(id) ? 'pending_order_review' : 'position_risk_review'
      else 'non_trading'
      end
    end
  end
end
