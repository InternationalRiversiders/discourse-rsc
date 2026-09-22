# frozen_string_literal: true

module DiscourseRsc
  class NotificationDelivery
    KINDS = %w[transfer post_tip issuance red_packet_claim red_packet_claimed_by red_packet_refund daily_reward prediction_settled stock_filled stock_closed stock_liquidated stock_stop_loss stock_take_profit stock_refunded].freeze

    def self.attempt(event)
      deliver(event)
    rescue StandardError => error
      event.with_lock do
        return if event.delivered_at
        attempts = event.attempts + 1
        event.update!(attempts: attempts, last_error: error.class.name.first(120), next_attempt_at: Time.current + [2**[attempts, 12].min, 3600].min.seconds)
      end
      Rails.logger.warn("RSC notification event=#{event.id}: #{error.class.name}")
    end

    def self.path(event)
      payload = event.payload
      if payload["packet_token"].present? && /\A[A-Za-z0-9_-]{8,100}\z/.match?(payload["packet_token"])
        return "/rsc/packets/#{payload['packet_token']}"
      end
      return "/rsc/market?instrument_id=#{payload['instrument_id'].to_i}&order_id=#{payload['order_id'].to_i}#rsc-order-#{payload['order_id'].to_i}" if event.kind.start_with?("stock_") && payload["instrument_id"]
      return "/rsc/market" if event.kind.start_with?("stock_")
      return "/rsc/sports?match_id=#{payload['match_id'].to_i}#rsc-match-#{payload['match_id'].to_i}" if event.kind == "prediction_settled" && payload["match_id"]
      return "/rsc/sports" if event.kind == "prediction_settled"
      "/rsc?journal_id=#{event.journal_id}#rsc-entry-#{event.journal_id}"
    end

    def self.deliver(event)
      Safety.ensure_writable!
      event.with_lock do
        return if event.delivered_at
        # Consume pending rewards from older releases without notifying the user.
        # New payouts only create ledger entries, not notification events.
        if event.kind == "daily_reward"
          event.update!(delivered_at: Time.current, last_error: nil)
          return
        end
        raise Error.new("unknown_event") unless KINDS.include?(event.kind)
        recipient = User.find_by(id: event.recipient_user_id)
        raise Error.new("recipient_not_found") unless recipient
        actor = User.find_by(id: event.payload["actor_user_id"])
        amount = Amount.display(Amount.parse(event.payload.fetch("amount")))
        text = I18n.t("discourse_rsc.notifications.#{event.kind}", locale: recipient.effective_locale, amount: amount,
          symbol: event.payload["symbol"], match: event.payload["match"],
          status: I18n.t("discourse_rsc.statuses.#{event.payload['status']}", locale: recipient.effective_locale, default: ""))
        text = "#{actor&.username || 'system'} #{text}" if %w[transfer post_tip issuance red_packet_claimed_by].include?(event.kind)
        data = {
          river_app: "rsc", river_text: text, river_path: path(event), river_icon: event.kind == "stock_liquidated" ? "triangle-exclamation" : "coins",
          rsc: true, rsc_kind: event.kind, rsc_amount: event.payload.fetch("amount"),
          display_username: actor&.username || "system", message: "discourse_rsc",
          rsc_path: path(event),
          rsc_journal_id: event.journal_id, rsc_symbol: event.payload["symbol"],
          rsc_match: event.payload["match"], rsc_status: event.payload["status"],
          topic_title: text,
        }
        attributes = { user_id: recipient.id, notification_type: Notification.types[:custom], data: data.to_json }
        if event.kind == "post_tip"
          post = Post.find_by(id: event.payload["post_id"])
          if post && Guardian.new(recipient).can_see?(post)
            attributes.merge!(topic_id: post.topic_id, post_number: post.post_number)
          end
        end
        notification = Notification.create!(attributes)
        # Same PostgreSQL transaction as notification creation, so retries do
        # not duplicate notifications, even after worker crashes.
        event.update!(notification_id: notification.id, delivered_at: Time.current, last_error: nil)
      end
    end
  end
end
