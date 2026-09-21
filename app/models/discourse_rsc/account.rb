# frozen_string_literal: true

module DiscourseRsc
  class Account < ActiveRecord::Base
    self.table_name = "discourse_rsc_accounts"
    # Ruby's BigDecimal#round(0) returns Integer. Keep the Ruby type unscaled
    # so SQL quoting uses BigDecimal rather than the strict 64-bit int path.
    # The DB column remains numeric(78, 0); Ledger accepts only integer units.
    attribute :balance_units, :decimal, precision: 78

    def self.wallet(user_id)
      raise Error.new("invalid_user") unless user_id.is_a?(Integer) && user_id.positive?
      create_or_find_by!(key: "wallet:#{user_id}") do |account|
        account.user_id = user_id
        account.kind = "wallet"
      end
    end

    def self.wallet_snapshot(user_id)
      find_by(user_id: user_id, kind: "wallet") || new(user_id: user_id, kind: "wallet", status: "active", balance_units: 0)
    end

    def self.issuance
      create_or_find_by!(key: "system:issuance") { |account| account.kind = "system" }
    end

    def self.internal(key, kind: "escrow")
      create_or_find_by!(key: key) { |account| account.kind = kind }
    end

    def balance
      Amount.format(balance_units)
    end
  end
end
