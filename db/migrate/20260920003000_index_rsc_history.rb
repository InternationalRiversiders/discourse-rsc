# frozen_string_literal: true
class IndexRscHistory < ActiveRecord::Migration[7.2]
  def change
    add_index :discourse_rsc_legacy_records, "source_table, (data ->> 'discourse_user_id')", name: "idx_rsc_history_user"
    add_index :discourse_rsc_legacy_records, "source_table, (data ->> 'post_id')", name: "idx_rsc_history_post"
  end
end
