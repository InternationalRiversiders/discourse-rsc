# frozen_string_literal: true
require "cgi"

module DiscourseRsc
  module PacketSharing
    TOKEN = /\A[A-Za-z0-9_-]{8,100}\z/
    LEGACY_URL = %r{\Ahttps?://coin\.river-side\.cc/red-packet/([A-Za-z0-9_-]{8,100})/?(?:[?#].*)?\z}

    def self.lookup(token)
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_native_trial_enabled && TOKEN.match?(token.to_s)
      Packet.find_by(token: token)
    end

    def self.url(packet)
      "#{Discourse.base_url}/rsc/packets/#{packet.token}"
    end

    def self.title(packet)
      "RS Coin 红包 · #{packet.message.presence || '打开红包'}"
    end

    def self.description(packet)
      sender = User.find_by(id: packet.user_id)&.username || "河畔用户"
      "#{sender} 发出的红包 · #{Amount.format(packet.total_units)} RSC · #{packet.claim_limit || packet.allocations.size} 份。打开查看领取状态。"
    end

    # Cooked posts are shared by every reader and cached. Include only the
    # public envelope; never claimants, allocations, remaining funds or a
    # potentially stale promise that the packet can still be claimed.
    def self.html(packet)
      return "" unless packet
      href = CGI.escapeHTML(url(packet))
      heading = CGI.escapeHTML(packet.message.presence || "RS Coin 红包")
      details = CGI.escapeHTML(description(packet))
      <<~HTML
        <aside class="onebox rsc-packet-onebox" data-onebox-src="#{href}">
          <header class="source"><a href="#{href}">RS Coin 红包</a></header>
          <article class="onebox-body">
            <span class="rsc-envelope" aria-hidden="true">🧧</span>
            <h3><a href="#{href}">#{heading}</a></h3>
            <p>#{details}</p>
          </article>
          <div class="onebox-metadata"></div>
        </aside>
      HTML
    end

    def self.local_packet(route)
      lookup(route[:token]) if route[:action] == "index"
    end
  end
end

# Resolve only the retired, known RSC domain locally before core attempts an
# external HTTP/DNS lookup. Everything else follows Discourse's normal pipeline.
module DiscourseRsc
  module LegacyPacketOnebox
    private
    def local_onebox(url, opts = {})
      match = PacketSharing::LEGACY_URL.match(url.to_s)
      target = match ? "#{Discourse.base_url}/rsc/packets/#{match[1]}" : url
      super(target, opts)
    end
  end

  module LegacyPacketInlineOnebox
    def lookup(url, opts = nil)
      match = PacketSharing::LEGACY_URL.match(url.to_s)
      return super unless match
      packet = PacketSharing.lookup(match[1])
      { url: url, title: PacketSharing.title(packet) } if packet
    end
  end
end
