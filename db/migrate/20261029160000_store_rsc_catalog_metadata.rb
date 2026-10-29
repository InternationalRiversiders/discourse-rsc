# frozen_string_literal: true
class StoreRscCatalogMetadata < ActiveRecord::Migration[7.2]
  def up
    add_column :discourse_rsc_instruments, :metadata, :jsonb, null: false, default: {}
    copy_legacy_metadata
  end

  def copy_legacy_metadata
    # Copy presentation/session metadata once; live reads no longer consult the archive.
    execute <<~SQL
      UPDATE discourse_rsc_instruments AS i
      SET metadata = jsonb_strip_nulls(jsonb_build_object(
        'display_symbol', l.data->'display_symbol', 'exchange', l.data->'exchange',
        'trading_hours', l.data->'trading_hours', 'catalog_rank', l.data->'catalog_rank',
        'catalog_id', l.data->'id')) || i.metadata
      FROM discourse_rsc_legacy_records AS l
      WHERE l.source_table = 'market_instruments' AND l.data->>'symbol' = i.symbol
    SQL
  end

  def down
    remove_column :discourse_rsc_instruments, :metadata
  end
end
