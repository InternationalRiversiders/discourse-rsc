# frozen_string_literal: true
module DiscourseRsc
  class PublicPacketsController < ::ApplicationController
    requires_plugin DiscourseRsc::PLUGIN_NAME
    skip_before_action :check_xhr, only: :index
    before_action :ensure_enabled

    def index
      @packet = Packet.find_by!(token: params.require(:token))
      @packet_title = PacketSharing.title(@packet)
      @description_meta = PacketSharing.description(@packet)
      @canonical_url = PacketSharing.url(@packet)
      render "discourse_rsc/public_packets/index"
    end

    def show
      packet = Packet.find_by!(token: params.require(:token))
      # Public sharing discloses the envelope, never allocations or claimants.
      status = packet.status == "open" && packet.expires_at <= Time.current ? "expired" : packet.status
      render_json_dump(token: packet.token, sender: User.find_by(id: packet.user_id)&.username,
        message: packet.message, total: Amount.format(packet.total_units), status: status,
        count: packet.claim_limit || packet.allocations.size, claimed_count: packet.claims.count,
        expires_at: packet.expires_at, preview: true)
    end

    private

    def ensure_enabled
      raise Discourse::InvalidAccess unless SiteSetting.rsc_native_trial_enabled
    end
  end
end
