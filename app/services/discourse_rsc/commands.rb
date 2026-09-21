# frozen_string_literal: true
module DiscourseRsc
  module Commands
    def self.lock(key)
      lock_id = Digest::SHA256.digest(key).unpack1("q>")
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
    end

    def self.run(user_id:, action:, request_id:, input:)
      Safety.ensure_writable!
      raise Error.new("invalid_request_id") unless request_id.is_a?(String) && /\A[A-Za-z0-9_-]{8,100}\z/.match?(request_id)
      key = "#{action}:#{user_id}:#{request_id}"
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(canonical(input)))
      Command.transaction do
        lock("command:#{key}")
        previous = Command.find_by(key: key)
        if previous
          raise Error.new("idempotency_conflict", status: 409) unless previous.fingerprint == fingerprint
          next previous.result.merge("replayed" => true)
        end
        result = JSON.parse(JSON.generate(yield))
        Command.create!(key: key, fingerprint: fingerprint, result: result, created_at: Time.current)
        result.merge("replayed" => false)
      end
    end

    def self.canonical(value)
      case value
      when Hash then value.map { |key, item| [key.to_s, canonical(item)] }.sort.to_h
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def self.move(user_id:, action:, request_id:, postings:, metadata: {}, event: nil, events: [], settlement: false)
      postings = postings.reject { |_, units| units.zero? }
      result = Ledger.post(operation: action, actor_user_id: user_id, request_id: request_id,
                           postings: postings, metadata: metadata, events: event ? [event] : events,
                           settlement: settlement)
      result.journal
    end

    def self.event(user_id, kind, payload)
      { recipient_user_id: user_id, kind: kind, payload: payload }
    end
  end
end
