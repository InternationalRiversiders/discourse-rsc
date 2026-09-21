# frozen_string_literal: true
require "securerandom"
module DiscourseRsc
  class RedPackets
    CENT = Amount::UNIT / 100

    def self.create(actor:, mode:, count:, amount:, minimum: "0.01", maximum: nil, days: 1, message: "", request_id:)
      Access.ensure_member!(actor)
      raise Error.new("invalid_packet") unless %w[fixed random].include?(mode) && count.is_a?(Integer) && count.between?(1, 200) && [1, 3, 5, 7, 30].include?(days) && message.is_a?(String) && message.length <= 80
      total = Amount.positive(amount, decimals: 2) * (mode == "fixed" ? count : 1)
      min = mode == "fixed" ? total / count : Amount.positive(minimum, decimals: 2)
      max = mode == "fixed" ? min : Amount.positive(maximum || amount, decimals: 2)
      raise Error.new("invalid_packet") unless min <= max && total >= min * count && total <= max * count && total <= Amount.parse("1000000")
      unless Wallet.limit_exempt?(actor)
        raise Error.new("packet_limit") if total > Amount.parse("300") || max > Amount.parse("100")
      end
      Commands.run(user_id: actor.id, action: "packet_create", request_id: request_id,
                   input: [mode, count, total.to_s, min.to_s, max.to_s, days, message]) do
        remaining = total / CENT
        allocations = count.times.map do |index|
          left = count - index - 1
          low = [min / CENT, remaining - left * (max / CENT)].max
          high = [max / CENT, remaining - left * (min / CENT)].min
          share = low + SecureRandom.random_number(high - low + 1)
          remaining -= share
          (share * CENT).to_s
        end.shuffle(random: Random.new(SecureRandom.random_number(2**64)))
        packet = Packet.create!(user_id: actor.id, token: SecureRandom.urlsafe_base64(24), mode: mode,
                                message: message, claim_limit: count, total_units: total, minimum_units: min, maximum_units: max, allocations: allocations, expires_at: Time.current + days.days)
        wallet = Account.wallet(actor.id)
        escrow = Account.internal("packet:#{packet.id}")
        Ledger.post(operation: "red_packet_open", actor_user_id: actor.id, request_id: request_id,
                    postings: { wallet.id => -total, escrow.id => total }, metadata: { packet_id: packet.id }) do
          Wallet.enforce_daily_limit!(actor, total)
        end
        { token: packet.token, total: Amount.format(total), count: count }
      end
    end

    def self.claim(actor:, token:, request_id:)
      Access.ensure_member!(actor)
      result = Commands.run(user_id: actor.id, action: "packet_claim", request_id: request_id, input: [token]) do
        packet = Packet.lock.find_by!(token: token)
        if packet.status == "open" && packet.expires_at <= Time.current
          refund_locked(packet, "expired")
          next({ expired: true }) # Commit the refund before returning an error.
        end
        raise Error.new("packet_closed", status: 409) unless packet.status == "open"
        raise Error.new("self_transfer") if packet.user_id == actor.id
        raise Error.new("packet_claimed", status: 409) if packet.claims.exists?(user_id: actor.id)
        units = packet.allocations.fetch(packet.claims.count).to_i
        claim = packet.claims.create!(user_id: actor.id, units: units, created_at: Time.current)
        escrow = Account.internal("packet:#{packet.id}")
        wallet = Account.wallet(actor.id)
        Commands.move(user_id: actor.id, action: "red_packet_claim", request_id: request_id,
                      postings: { escrow.id => -units, wallet.id => units }, metadata: { claim_id: claim.id, packet_id: packet.id, packet_token: packet.token, sender_user_id: packet.user_id },
                      events: [Commands.event(actor.id, "red_packet_claim", { "packet_token" => packet.token, "amount" => Amount.format(units), "actor_user_id" => packet.user_id }),
                               Commands.event(packet.user_id, "red_packet_claimed_by", { "packet_token" => packet.token, "amount" => Amount.format(units), "actor_user_id" => actor.id })])
        packet.update!(status: "exhausted") if packet.claims.count == packet.allocations.size
        { amount: Amount.format(units), token: token }
      end
      raise Error.new("packet_expired", status: 409) if result["expired"]
      result
    end

    def self.close(actor:, token:, request_id:)
      Access.ensure_member!(actor)
      Commands.run(user_id: actor.id, action: "packet_close", request_id: request_id, input: [token]) do
        packet = Packet.lock.find_by!(token: token, user_id: actor.id)
        refund_locked(packet, "closed")
        { token: token, status: packet.status }
      end
    end

    def self.expire
      Safety.ensure_writable!
      Packet.where(status: "open").where("expires_at <= ?", Time.current).find_each do |packet|
        packet.with_lock { refund_locked(packet, "expired") if packet.status == "open" && packet.expires_at <= Time.current }
      end
    end

    def self.refund_locked(packet, status)
      return unless packet.status == "open"
      escrow = Account.internal("packet:#{packet.id}")
      wallet = Account.wallet(packet.user_id)
      units = escrow.balance_units.to_i
      if units.positive?
        Commands.move(user_id: packet.user_id, action: "red_packet_refund", request_id: "packet-refund-#{packet.id}",
                      postings: { escrow.id => -units, wallet.id => units }, metadata: { packet_id: packet.id, reason: status }, settlement: true,
                      event: Commands.event(packet.user_id, "red_packet_refund", { "packet_token" => packet.token, "amount" => Amount.format(units) }))
      end
      packet.update!(status: status)
    end
    private_class_method :refund_locked
  end
end
