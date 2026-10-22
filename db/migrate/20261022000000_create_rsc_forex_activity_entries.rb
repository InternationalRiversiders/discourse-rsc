# frozen_string_literal: true
class CreateRscForexActivityEntries < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_forex_activity_entries do |t|
      t.string :campaign_key, null: false
      t.bigint :user_id, null: false
      t.bigint :instrument_id, null: false
      # Keep the entry after the exchange deletes a fully closed position.
      t.bigint :position_id, null: false
      t.integer :fee_bps, null: false
      t.decimal :realized_units, precision: 78, scale: 0, null: false, default: 0
      t.decimal :mark_units, precision: 78, scale: 0, null: false, default: 0
      t.decimal :mark_price_units, precision: 78, scale: 0
      t.decimal :final_units, precision: 78, scale: 0
      t.jsonb :trade_days, null: false, default: []
      t.boolean :liquidated, null: false, default: false
      t.datetime :opened_at, null: false
      t.datetime :closed_at
      t.datetime :marked_at
      t.datetime :finalized_at
      t.timestamps
    end
    add_index :discourse_rsc_forex_activity_entries, :position_id, unique: true, name: 'idx_rsc_fx_activity_position'
    add_index :discourse_rsc_forex_activity_entries, [:campaign_key, :user_id], name: 'idx_rsc_fx_activity_user'
  end
end
