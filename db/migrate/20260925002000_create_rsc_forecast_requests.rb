# frozen_string_literal: true
class CreateRscForecastRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_rsc_forecast_requests do |t|
      t.string :external_id, null: false
      t.bigint :user_id, null: false
      t.bigint :reviewer_id
      t.bigint :market_id
      t.string :question, null: false
      t.string :terms_digest, null: false
      t.string :status, null: false, default: 'pending'
      t.text :reason, null: false, default: ''
      t.text :review_reason, null: false, default: ''
      t.timestamps
    end
    add_index :discourse_rsc_forecast_requests, [:external_id, :user_id], unique: true, name: 'rsc_forecast_request_user'
    add_index :discourse_rsc_forecast_requests, [:status, :id], name: 'rsc_forecast_request_status'
    add_foreign_key :discourse_rsc_forecast_requests, :users, column: :user_id
    add_foreign_key :discourse_rsc_forecast_requests, :users, column: :reviewer_id
    add_foreign_key :discourse_rsc_forecast_requests, :discourse_rsc_forecast_markets, column: :market_id
    add_check_constraint :discourse_rsc_forecast_requests, "status IN ('pending','approved','rejected')", name: 'rsc_forecast_request_state'
  end
end
