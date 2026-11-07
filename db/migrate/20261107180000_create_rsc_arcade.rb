# frozen_string_literal: true
class CreateRscArcade < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_arcade_periods do |t|
      t.datetime :ends_at, null: false
      t.jsonb :prizes, null: false, default: []
      t.jsonb :results, null: false, default: {}
      t.datetime :settled_at
      t.timestamps
    end
    add_index :discourse_rsc_arcade_periods, :ends_at, unique: true
    create_table :discourse_rsc_arcade_runs do |t|
      t.bigint :user_id, null: false
      t.bigint :period_id, null: false
      t.string :game, null: false
      t.string :status, null: false, default: 'playing'
      t.string :start_key, null: false
      t.integer :version, null: false, default: 0
      t.integer :score, null: false, default: 0
      t.jsonb :state, null: false, default: {}
      t.jsonb :inputs, null: false, default: []
      t.string :last_key
      t.string :last_digest
      t.datetime :expires_at, null: false
      t.datetime :finished_at
      t.timestamps
    end
    add_index :discourse_rsc_arcade_runs, [:user_id, :start_key], unique: true
    add_index :discourse_rsc_arcade_runs, [:user_id, :game], unique: true, where: "status = 'playing'", name: 'rsc_arcade_active'
    add_index :discourse_rsc_arcade_runs, [:period_id, :game, :score], name: 'rsc_arcade_ranking'
    add_check_constraint :discourse_rsc_arcade_runs, "score >= 0 AND version >= 0 AND status IN ('playing','finished','expired')", name: 'rsc_arcade_valid'
  end
end
