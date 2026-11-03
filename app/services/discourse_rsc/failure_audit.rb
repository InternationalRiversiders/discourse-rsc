# frozen_string_literal: true
module DiscourseRsc
  module FailureAudit
    FIELDS = %i[id instrument_id market_id position_id order_id side quantity leverage high_risk take_profit stop_loss amount stake pick cancel_pending request_id].freeze

    def self.record(controller:, error:)
      actor = controller.current_user
      return unless actor
      return if Safety.read_only? || %w[admin_required member_required].include?(error.code)
      params = controller.params
      operation = "#{controller.controller_name}.#{controller.action_name}"
      details = params.permit(*FIELDS).to_h.transform_values { |v| v.to_s.first(100) }
      details.merge!('error' => error.code, 'status' => error.status, 'operation' => operation,
        'context' => error.details, 'observed_at' => Time.current.iso8601(6))
      # This is a post-rejection snapshot, not an invented execution-time price.
      if controller.controller_name == 'dashboard'
        position = Position.find_by(id: params[:id], user_id: actor.id) if %w[protect add_margin].include?(controller.action_name)
        order = Order.find_by(id: params[:id], user_id: actor.id) if controller.action_name == 'cancel_order'
        instrument = Instrument.find_by(id: position&.instrument_id || order&.instrument_id || params[:instrument_id])
        if instrument
          details['instrument_id'] = instrument.id
          details['quote_snapshot'] = instrument.quote.slice('price', 'source', 'source_time', 'received_at', 'delay_seconds').merge('verification_status' => instrument.quote.dig('verification', 'status'))
          details['provider_error'] = instrument.provider_error
        end
        wallet = Account.find_by(key: "wallet:#{actor.id}")
        details['available_balance_snapshot'] = wallet.balance if wallet
      end
      # Keep existing order metrics compatible; other actions now get the same trail.
      action = operation == 'dashboard.order' ? 'order_rejected' : 'request_rejected'
      Audit.create!(actor_user_id: actor.id, action: action, details: details, created_at: Time.current)
    rescue StandardError => error
      Rails.logger.warn("RSC failure audit unavailable: #{error.class}")
    end
  end
end
