# frozen_string_literal: true

require "digest"
require "json"

module DiscourseRsc
  # The only writer of account balances. Callers supply integer atomic units.
  # Locks are acquired by account ID to make cross transfers deadlock-safe.
  class Ledger
    Result = Struct.new(:journal, :replayed, keyword_init: true)

    def self.post(operation:, actor_user_id:, request_id:, postings:, metadata: {}, events: [], settlement: false, &validate)
      # Import is an offline, explicitly gated operation and is allowed while
      # read-only. Every other ledger write, including direct service calls, stops.
      if defined?(Safety) && !(operation == "legacy_opening" && !SiteSetting.rsc_enabled)
        Safety.ensure_writable!
      end
      unless /\A[a-z_]{1,40}\z/.match?(operation.to_s) &&
               request_id.is_a?(String) && /\A[A-Za-z0-9_-]{8,100}\z/.match?(request_id)
        raise Error.new("invalid_request_id")
      end
      unless postings.size >= 2 && postings.keys.all? { |id| id.is_a?(Integer) && id.positive? } &&
               postings.values.all? { |v| v.is_a?(Integer) && !v.zero? && v.abs <= Amount::MAX_UNITS } &&
               postings.values.sum.zero?
        raise Error.new("unbalanced_journal")
      end
      request_key = "#{operation}:#{actor_user_id}:#{request_id}"
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(canonical([postings, metadata, events])))

      Journal.transaction do
        # Serialize the same request even if a replay changes its recipient accounts.
        lock_id = Digest::SHA256.digest(request_key).unpack1("q>")
        Journal.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
        existing = Journal.find_by(request_key: request_key)
        if existing
          raise Error.new("idempotency_conflict", status: 409) unless existing.fingerprint == fingerprint
          next Result.new(journal: existing, replayed: true)
        end

        accounts = Account.where(id: postings.keys).order(:id).lock.to_a
        raise Error.new("account_not_found", status: 404) unless accounts.size == postings.size
        accounts.each do |account|
          # Only internal settlement callers may credit frozen wallets. Never
          # allow a settlement flag to authorize debiting a frozen wallet.
          allowed = account.status == "active" || (settlement && postings.fetch(account.id).positive?)
          raise Error.new("wallet_frozen", status: 403) unless allowed
          next_balance = account.balance_units.to_i + postings.fetch(account.id)
          if account.kind != "system" && next_balance.negative?
            raise Error.new("insufficient_balance", status: 409)
          end
          raise Error.new("amount_overflow") if next_balance.abs > Amount::MAX_UNITS
        end
        validate&.call(accounts)

        now = Time.current
        journal = Journal.create!(request_key: request_key, fingerprint: fingerprint,
                                  operation: operation, actor_user_id: actor_user_id,
                                  metadata: metadata, created_at: now)
        accounts.each do |account|
          units = postings.fetch(account.id)
          balance = account.balance_units.to_i + units
          account.update!(balance_units: balance)
          Entry.create!(journal_id: journal.id, account_id: account.id, units: units,
                        balance_after_units: balance, created_at: now)
        end
        events.each do |event|
          Event.create!(journal_id: journal.id, recipient_user_id: event.fetch(:recipient_user_id),
                        kind: event.fetch(:kind), payload: event.fetch(:payload), next_attempt_at: now)
        end
        Result.new(journal: journal, replayed: false)
      end
    end

    def self.canonical(value)
      case value
      when Hash
        value.map { |key, item| [key.to_s, canonical(item)] }.sort.to_h
      when Array
        value.map { |item| canonical(item) }
      else
        value
      end
    end
    private_class_method :canonical
  end
end
