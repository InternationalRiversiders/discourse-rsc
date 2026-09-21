# frozen_string_literal: true
class RetainRscAccountOwners < ActiveRecord::Migration[7.2]
  def change
    # Complements early UI/service guards and closes the race between a user's
    # first wallet creation and deletion. Historical ledger ownership is retained.
    add_foreign_key :discourse_rsc_accounts, :users, column: :user_id, on_delete: :restrict
  end
end
