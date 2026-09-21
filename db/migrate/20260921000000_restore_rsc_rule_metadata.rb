# frozen_string_literal: true
class RestoreRscRuleMetadata < ActiveRecord::Migration[7.2]
  def change
    add_column :discourse_rsc_market_requests, :details, :jsonb, null: false, default: {}
    add_column :discourse_rsc_instruments, :asset_type, :string, null: false, default: ""
    add_column :discourse_rsc_exemptions, :starts_at, :datetime
    add_column :discourse_rsc_accounts, :status_reason, :text
    add_column :discourse_rsc_packets, :claim_limit, :integer
    add_column :discourse_rsc_packets, :minimum_units, :decimal, precision: 78, scale: 0
    add_column :discourse_rsc_packets, :maximum_units, :decimal, precision: 78, scale: 0
  end
end
