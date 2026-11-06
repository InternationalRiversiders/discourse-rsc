# frozen_string_literal: true
class CreateRscGameRounds < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_game_rounds do |t|
      t.bigint :user_id, null: false
      t.string :game, null: false
      t.string :status, null: false, default: 'playing'
      t.integer :version, null: false, default: 0
      t.decimal :stake_units, precision: 78, scale: 0, null: false
      t.decimal :payout_units, precision: 78, scale: 0, null: false, default: 0
      t.jsonb :state, null: false, default: {}
      t.datetime :settled_at
      t.timestamps
    end
    add_index :discourse_rsc_game_rounds, [:user_id, :id], name: 'idx_rsc_games_history'
    add_index :discourse_rsc_game_rounds, :user_id, unique: true, where: "status = 'playing'", name: 'idx_rsc_games_one_active'
    add_check_constraint :discourse_rsc_game_rounds, "stake_units > 0 AND payout_units >= 0 AND version >= 0", name: 'rsc_game_amounts'
    add_check_constraint :discourse_rsc_game_rounds, "status IN ('playing','settled')", name: 'rsc_game_status'
  end
end
