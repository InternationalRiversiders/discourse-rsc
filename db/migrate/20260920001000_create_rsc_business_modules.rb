# frozen_string_literal: true
class CreateRscBusinessModules < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_commands do |t|
      t.string :key, null: false
      t.string :fingerprint, null: false
      t.jsonb :result, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :discourse_rsc_commands, :key, unique: true

    create_table :discourse_rsc_instruments do |t|
      t.string :symbol, null: false
      t.string :name, null: false
      t.string :category, null: false, default: "us"
      t.string :currency, null: false, default: "USD"
      t.string :provider_symbol
      t.integer :fee_bps, null: false, default: 5
      t.decimal :minimum_units, precision: 78, scale: 0, null: false, default: 1_000_000_000_000_000_000
      t.decimal :step_units, precision: 78, scale: 0, null: false, default: 1_000_000_000_000_000_000
      t.boolean :active, null: false, default: true
      t.jsonb :quote, null: false, default: {}
      t.jsonb :history, null: false, default: []
      t.timestamps
    end
    add_index :discourse_rsc_instruments, :symbol, unique: true

    create_table :discourse_rsc_positions do |t|
      t.integer :user_id, null: false
      t.bigint :instrument_id, null: false
      t.string :side, null: false
      t.integer :leverage, null: false
      %i[quantity_units average_units margin_units].each { |name| t.decimal name, precision: 78, scale: 0, null: false, default: 0 }
      %i[take_profit_units stop_loss_units].each { |name| t.decimal name, precision: 78, scale: 0 }
      t.datetime :hold_until
      t.timestamps
    end
    add_index :discourse_rsc_positions, [:user_id, :instrument_id], unique: true, name: "rsc_position_owner_symbol"
    add_foreign_key :discourse_rsc_positions, :discourse_rsc_instruments, column: :instrument_id
    add_check_constraint :discourse_rsc_positions, "quantity_units >= 0 AND margin_units >= 0 AND average_units >= 0", name: "rsc_position_nonnegative"

    create_table :discourse_rsc_orders do |t|
      t.integer :user_id, null: false
      t.bigint :instrument_id, null: false
      t.string :side, null: false
      t.integer :leverage, null: false
      t.string :status, null: false
      t.decimal :quantity_units, precision: 78, scale: 0, null: false
      t.decimal :reserved_units, precision: 78, scale: 0, null: false, default: 0
      t.jsonb :details, null: false, default: {}
      t.datetime :execute_at
      t.datetime :expires_at
      t.timestamps
    end
    add_index :discourse_rsc_orders, [:user_id, :created_at]
    add_index :discourse_rsc_orders, :execute_at, where: "status = 'pending'"
    add_index :discourse_rsc_orders, [:user_id, :instrument_id], unique: true, where: "status = 'pending'", name: "rsc_one_pending_order"
    add_foreign_key :discourse_rsc_orders, :discourse_rsc_instruments, column: :instrument_id

    create_table :discourse_rsc_sport_matches do |t|
      t.string :external_id, null: false
      t.string :sport, null: false, default: "soccer"
      t.string :league, null: false
      t.string :home, null: false
      t.string :away, null: false
      t.datetime :starts_at, null: false
      t.string :status, null: false, default: "scheduled"
      t.boolean :allow_draw, null: false, default: true
      t.jsonb :odds, null: false, default: {}
      t.datetime :odds_at
      t.jsonb :score, null: false, default: {}
      t.string :result
      t.datetime :confirmed_at
      t.string :source, null: false, default: "manual"
      t.timestamps
    end
    add_index :discourse_rsc_sport_matches, :external_id, unique: true
    add_index :discourse_rsc_sport_matches, [:status, :starts_at]

    create_table :discourse_rsc_predictions do |t|
      t.integer :user_id, null: false
      t.bigint :sport_match_id, null: false
      t.string :pick, null: false
      t.decimal :stake_units, precision: 78, scale: 0, null: false
      t.string :odds, null: false
      t.string :status, null: false, default: "pending"
      t.decimal :payout_units, precision: 78, scale: 0, null: false, default: 0
      t.jsonb :revisions, null: false, default: []
      t.datetime :settled_at
      t.timestamps
    end
    add_index :discourse_rsc_predictions, [:user_id, :sport_match_id], unique: true, name: "rsc_prediction_owner_match"
    add_foreign_key :discourse_rsc_predictions, :discourse_rsc_sport_matches, column: :sport_match_id

    create_table :discourse_rsc_packets do |t|
      t.integer :user_id, null: false
      t.string :token, null: false
      t.string :mode, null: false
      t.string :message, null: false, default: ""
      t.string :status, null: false, default: "open"
      t.decimal :total_units, precision: 78, scale: 0, null: false
      t.jsonb :allocations, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :discourse_rsc_packets, :token, unique: true
    create_table :discourse_rsc_packet_claims do |t|
      t.bigint :packet_id, null: false
      t.integer :user_id, null: false
      t.decimal :units, precision: 78, scale: 0, null: false
      t.datetime :created_at, null: false
    end
    add_index :discourse_rsc_packet_claims, [:packet_id, :user_id], unique: true
    add_foreign_key :discourse_rsc_packet_claims, :discourse_rsc_packets, column: :packet_id
  end
end
