# frozen_string_literal: true
class CreateRscLottery < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_lottery_draws do |t|
      t.datetime :draw_at, null: false
      t.string :number
      t.datetime :settled_at
      t.integer :winning_tickets, null: false, default: 0
      t.decimal :pool_units, precision: 78, scale: 0, null: false, default: 0
      t.decimal :paid_units, precision: 78, scale: 0, null: false, default: 0
      t.decimal :small_paid_units, precision: 78, scale: 0, null: false, default: 0
      t.timestamps
    end
    add_index :discourse_rsc_lottery_draws, :draw_at, unique: true
    add_index :discourse_rsc_lottery_draws, '(1)', unique: true, where: 'settled_at IS NULL', name: 'idx_rsc_lottery_open'
    add_check_constraint :discourse_rsc_lottery_draws, "(settled_at IS NULL AND number IS NULL) OR (settled_at IS NOT NULL AND number IS NOT NULL AND number ~ '^[0-9]{4}$')", name: 'rsc_lottery_result'
    add_check_constraint :discourse_rsc_lottery_draws, 'pool_units >= paid_units AND paid_units >= small_paid_units AND small_paid_units >= 0 AND winning_tickets >= 0', name: 'rsc_lottery_payout'
    create_table :discourse_rsc_lottery_tickets do |t|
      t.bigint :draw_id, null: false
      t.bigint :user_id, null: false
      t.string :number, null: false
      t.integer :quantity, null: false
      t.decimal :payout_units, precision: 78, scale: 0, null: false, default: 0
      t.timestamps
    end
    add_foreign_key :discourse_rsc_lottery_tickets, :discourse_rsc_lottery_draws, column: :draw_id
    add_index :discourse_rsc_lottery_tickets, [:draw_id, :user_id], name: 'idx_rsc_lottery_user'
    add_index :discourse_rsc_lottery_tickets, [:draw_id, :number], name: 'idx_rsc_lottery_number'
    add_index :discourse_rsc_lottery_tickets, [:user_id, :id], name: 'idx_rsc_lottery_history'
    add_check_constraint :discourse_rsc_lottery_tickets, "number ~ '^[0-9]{4}$' AND quantity BETWEEN 1 AND 20 AND payout_units >= 0", name: 'rsc_lottery_ticket'
  end
end
