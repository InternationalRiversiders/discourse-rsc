# frozen_string_literal: true
class RestoreRscMarketHistory < ActiveRecord::Migration[7.2]
  def change
    add_column :discourse_rsc_history_caches, :source, :string, null: false, default: "provider"
    add_column :discourse_rsc_history_caches, :currency, :string
    add_index :discourse_rsc_legacy_records, "source_table, (data ->> 'instrument_id')", name: "idx_rsc_history_instrument"
  end
end
