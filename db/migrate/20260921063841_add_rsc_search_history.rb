# frozen_string_literal: true
class AddRscSearchHistory < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_searches do |t|
      t.bigint :user_id, null: false
      t.string :query, null: false, limit: 80
      t.integer :result_count, null: false, default: 0
      t.datetime :created_at, null: false
    end
    add_index :discourse_rsc_searches, :created_at
    add_index :discourse_rsc_searches, [:user_id, :created_at]
  end
end
