# frozen_string_literal: true

module DiscourseRsc
  class Wallet
    def self.transfer(actor:, recipient:, amount:, request_id:, post: nil)
      Safety.ensure_writable!
      Access.ensure_member!(actor)
      Access.ensure_member!(recipient)
      raise Error.new("self_transfer") if actor.id == recipient.id
      units = Amount.positive(amount, decimals: 2)
      if post
        Guardian.new(actor).ensure_can_see!(post)
        unless post.user_id == recipient.id && post.post_type == Post.types[:regular] &&
                 !post.hidden && !post.deleted_at && !post.topic.deleted_at && post.topic.regular?
          raise Error.new("invalid_post")
        end
      end
      sender = Account.wallet(actor.id)
      receiver = Account.wallet(recipient.id)
      operation = post ? "post_tip" : "transfer"
      metadata = { "amount" => Amount.format(units), "recipient_user_id" => recipient.id }
      metadata.merge!("post_id" => post.id, "topic_id" => post.topic_id, "post_number" => post.post_number) if post
      Ledger.post(operation: operation, actor_user_id: actor.id, request_id: request_id,
                  postings: { sender.id => -units, receiver.id => units }, metadata: metadata,
                  events: [{ recipient_user_id: recipient.id, kind: operation,
                             payload: metadata.merge("actor_user_id" => actor.id) }]) do
        enforce_daily_limit!(actor, units)
      end
    end

    def self.issue(actor:, recipient:, amount:, reason:, request_id:)
      Safety.ensure_writable!
      raise Error.new("admin_required", status: 403) unless Access.admin?(actor)
      Access.ensure_member!(recipient)
      raise Error.new("reason_required") unless reason.is_a?(String) && reason.strip.length.between?(1, 500)
      units = Amount.positive(amount)
      source = Account.issuance
      receiver = Account.wallet(recipient.id)
      metadata = { "amount" => Amount.format(units), "recipient_user_id" => recipient.id, "reason" => reason.strip }
      Ledger.post(operation: "issuance", actor_user_id: actor.id, request_id: request_id,
                  postings: { source.id => -units, receiver.id => units }, metadata: metadata,
                  events: [{ recipient_user_id: recipient.id, kind: "issuance",
                             payload: { "amount" => metadata["amount"], "actor_user_id" => actor.id } }])
    end

    def self.limit_exempt?(actor)
      Access.admin?(actor) || Exemption.where(user_id: actor.id).where("expires_at > ? AND (starts_at IS NULL OR starts_at <= ?)", Time.current, Time.current).exists?
    end

    def self.enforce_daily_limit!(actor, units)
      return if limit_exempt?(actor)
      now = Time.current.utc
      start = Time.utc(*(now + 8.hours).to_date.to_s.split("-").map(&:to_i)) - 8.hours
      journals = Journal.where(actor_user_id: actor.id, operation: %w[transfer post_tip red_packet_open])
                        .where(created_at: start...(start + 1.day))
      legacy = LegacyRecord.where(source_table: "ledger_entries").where("data ->> 'discourse_user_id' = ? AND data ->> 'direction' = 'debit'", actor.id.to_s)
        .where("data ->> 'type' IN ('transfer', 'post_tip', 'red_packet_fund')").pluck(:data).select { |row| (start...(start + 1.day)).cover?(Time.iso8601(row.fetch("created_at"))) }
      if journals.count + legacy.size >= SiteSetting.rsc_daily_outgoing_count
        raise Error.new("daily_count_limit", status: 429)
      end
      # The caller holds the sender account lock, so concurrent requests cannot
      # both pass a limit check against the same pre-transfer state.
      spent = Entry.joins(:journal).where(journal_id: journals.select(:id)).where("units < 0").sum(:units).abs.to_i
      spent += legacy.sum { |row| Amount.parse(row.fetch("amount_rsc")) }
      maximum = Amount.positive(SiteSetting.rsc_daily_outgoing_amount)
      raise Error.new("daily_amount_limit", status: 429) if spent + units > maximum
    end
  end
end
