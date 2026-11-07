# frozen_string_literal: true
class WidenRscArcadeScore < ActiveRecord::Migration[7.2]
  def up
    # Unlimited games must not overflow a signed 32-bit score. Old code reads
    # bigint transparently; no columns are removed during the A/B transition.
    execute "SET LOCAL lock_timeout = '3s'"
    execute "SET LOCAL statement_timeout = '30s'"
    change_column :discourse_rsc_arcade_runs, :score, :bigint, null: false, default: 0
  end
  def down
    raise ActiveRecord::IrreversibleMigration, 'Keep earned scores beyond the old integer range'
  end
end
