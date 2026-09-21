# frozen_string_literal: true
class ExtendRscNativeFeatures < ActiveRecord::Migration[7.2]
  def change
    add_column :discourse_rsc_instruments, :provider, :string, null: false, default: "manual"
    add_column :discourse_rsc_instruments, :provider_error, :string
    add_column :discourse_rsc_instruments, :synced_at, :datetime
    add_column :discourse_rsc_sport_matches, :provider_data, :jsonb, null: false, default: {}
    create_table :discourse_rsc_market_requests do |t|
      t.bigint :user_id, null: false
      t.string :symbol, null: false
      t.string :status, null: false, default: "pending"
      t.timestamps
    end
    add_index :discourse_rsc_market_requests, [:user_id, :symbol], unique: true
    create_table :discourse_rsc_audits do |t|
      t.bigint :actor_user_id
      t.string :action, null: false
      t.jsonb :details, null: false, default: {}
      t.datetime :created_at, null: false
    end
    create_table :discourse_rsc_history_caches do |t|
      t.bigint :instrument_id, null: false
      t.string :range, null: false
      t.jsonb :candles, null: false, default: []
      t.datetime :updated_at, null: false
    end
    add_index :discourse_rsc_history_caches, [:instrument_id, :range], unique: true
    create_table :discourse_rsc_exemptions do |t|
      t.bigint :user_id, null: false
      t.datetime :expires_at, null: false
      t.string :reason, null: false
      t.bigint :actor_user_id, null: false
      t.timestamps
    end
    add_index :discourse_rsc_exemptions, [:user_id, :expires_at]
    create_table :discourse_rsc_legacy_records do |t|
      t.string :source_table, null: false
      t.string :source_id, null: false
      t.jsonb :data, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :discourse_rsc_legacy_records, [:source_table, :source_id], unique: true
  end
end
