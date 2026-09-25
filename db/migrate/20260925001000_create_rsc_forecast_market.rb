# frozen_string_literal: true
class CreateRscForecastMarket < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_forecast_markets do |t|
      t.string :external_id, null: false
      t.string :condition_id, null: false
      t.string :event_title, null: false
      t.string :question, null: false
      t.string :slug, null: false
      t.text :rules, null: false
      t.jsonb :outcomes, null: false, default: []
      t.jsonb :token_ids, null: false, default: []
      t.jsonb :prices, null: false, default: []
      t.decimal :volume, precision: 30, scale: 2, default: 0
      t.decimal :liquidity, precision: 30, scale: 2, default: 0
      t.string :state, null: false, default: 'open'
      t.boolean :featured, null: false, default: true
      t.string :terms_digest, null: false
      t.datetime :ends_at, null: false
      t.datetime :synced_at
      t.jsonb :resolution, null: false, default: {}
      t.string :resolution_digest
      t.datetime :resolution_seen_at
      t.datetime :confirmed_at
      t.datetime :settled_at
      t.timestamps
    end
    add_index :discourse_rsc_forecast_markets, :external_id, unique: true, name: 'rsc_forecast_external'
    add_index :discourse_rsc_forecast_markets, :condition_id, unique: true, name: 'rsc_forecast_condition'
    create_table :discourse_rsc_forecast_positions do |t|
      t.bigint :market_id, null: false
      t.bigint :user_id, null: false
      t.integer :outcome, null: false
      t.decimal :shares_units, precision: 78, scale: 0, null: false, default: 0
      t.decimal :cost_units, precision: 78, scale: 0, null: false, default: 0
      t.decimal :realized_units, precision: 78, scale: 0, null: false, default: 0
      t.string :state, null: false, default: 'open'
      t.timestamps
    end
    add_index :discourse_rsc_forecast_positions, [:market_id, :user_id, :outcome], unique: true, name: 'rsc_forecast_holding'
    create_table :discourse_rsc_forecast_quotes do |t|
      t.bigint :market_id, null: false
      t.bigint :user_id, null: false
      t.string :token, null: false
      t.integer :outcome, null: false
      t.string :side, null: false
      t.decimal :shares_units, precision: 78, scale: 0, null: false
      t.decimal :cash_units, precision: 78, scale: 0, null: false
      t.string :terms_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end
    add_index :discourse_rsc_forecast_quotes, :token, unique: true, name: 'rsc_forecast_quote_token'
    add_index :discourse_rsc_forecast_quotes, :expires_at, name: 'rsc_forecast_quote_expiry'
    create_table :discourse_rsc_forecast_trades do |t|
      t.bigint :market_id, null: false
      t.bigint :user_id, null: false
      t.bigint :journal_id
      t.integer :outcome, null: false
      t.string :side, null: false
      t.decimal :shares_units, precision: 78, scale: 0, null: false
      t.decimal :cash_units, precision: 78, scale: 0, null: false
      t.decimal :pnl_units, precision: 78, scale: 0, null: false, default: 0
      t.timestamps
    end
    add_index :discourse_rsc_forecast_trades, [:user_id, :id], name: 'rsc_forecast_trade_history'
    add_check_constraint :discourse_rsc_forecast_positions, 'shares_units >= 0 AND cost_units >= 0 AND outcome IN (0,1)', name: 'rsc_forecast_position_bounds'
    add_check_constraint :discourse_rsc_forecast_quotes, "shares_units > 0 AND cash_units > 0 AND outcome IN (0,1) AND side IN ('buy','sell')", name: 'rsc_forecast_quote_bounds'
    add_foreign_key :discourse_rsc_forecast_trades, :discourse_rsc_journals, column: :journal_id
    %w[positions quotes trades].each do |table|
      add_foreign_key "discourse_rsc_forecast_#{table}", :discourse_rsc_forecast_markets, column: :market_id
      add_foreign_key "discourse_rsc_forecast_#{table}", :users, column: :user_id
    end
  end
end
