# frozen_string_literal: true
class AddRscCashDividends < ActiveRecord::Migration[7.2]
  def change
    add_column :discourse_rsc_positions, :dividend_units, :decimal, precision: 78, scale: 0, null: false, default: 0
    create_table :discourse_rsc_dividends do |t|
      t.bigint :instrument_id, null: false
      t.date :ex_date, null: false
      t.datetime :effective_at, null: false
      t.decimal :per_share_units, precision: 78, scale: 0, null: false
      t.string :currency, null: false, default: 'USD'
      t.string :status, null: false, default: 'draft'
      t.string :source_url, null: false
      t.text :reason, null: false
      t.bigint :created_by_id, null: false
      t.bigint :reviewed_by_id
      t.datetime :applied_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :discourse_rsc_dividends, [:instrument_id, :ex_date], unique: true, name: 'rsc_dividend_unique_date'
    add_index :discourse_rsc_dividends, [:status, :effective_at], name: 'rsc_dividend_due'
    add_foreign_key :discourse_rsc_dividends, :discourse_rsc_instruments, column: :instrument_id
    add_check_constraint :discourse_rsc_dividends, "per_share_units > 0 AND currency = 'USD' AND status IN ('draft','approved','canceled','applied')", name: 'rsc_dividend_valid'
    create_table :discourse_rsc_dividend_entries do |t|
      t.bigint :dividend_id, null: false
      # Historical position IDs survive full closes.
      t.bigint :position_id, null: false
      t.bigint :user_id, null: false
      t.string :side, null: false
      t.decimal :quantity_units, precision: 78, scale: 0, null: false
      t.decimal :amount_units, precision: 78, scale: 0, null: false
      t.datetime :created_at, null: false
    end
    add_index :discourse_rsc_dividend_entries, [:dividend_id, :position_id], unique: true, name: 'rsc_dividend_position_unique'
    add_index :discourse_rsc_dividend_entries, [:user_id, :id], name: 'rsc_dividend_user_history'
    add_foreign_key :discourse_rsc_dividend_entries, :discourse_rsc_dividends, column: :dividend_id
  end
end
