# frozen_string_literal: true
class CreateRscLotteryPlans < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_lottery_plans do |t|
      t.bigint :user_id, null: false
      t.jsonb :selections, null: false, default: []
      t.boolean :enabled, null: false, default: false
      t.integer :version, null: false, default: 0
      t.datetime :effective_at, null: false
      t.bigint :last_draw_id
      t.jsonb :last_result, null: false, default: {}
      t.timestamps
    end
    add_index :discourse_rsc_lottery_plans, :user_id, unique: true
    add_index :discourse_rsc_lottery_plans, :id, where: 'enabled', name: 'idx_rsc_lottery_active_plans'
    add_foreign_key :discourse_rsc_lottery_plans, :users, on_delete: :cascade
    add_check_constraint :discourse_rsc_lottery_plans, "version >= 0 AND jsonb_typeof(selections) = 'array' AND jsonb_array_length(selections) <= 20", name: 'rsc_lottery_plan_valid'
  end
end
