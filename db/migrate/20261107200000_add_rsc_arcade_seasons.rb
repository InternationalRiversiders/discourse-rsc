# frozen_string_literal: true
class AddRscArcadeSeasons < ActiveRecord::Migration[7.2]
  def change
    add_column :discourse_rsc_arcade_periods, :starts_at, :datetime
    add_column :discourse_rsc_arcade_periods, :game, :string
    add_column :discourse_rsc_arcade_periods, :cadence, :string
    add_column :discourse_rsc_arcade_periods, :ordinal, :integer
    add_index :discourse_rsc_arcade_periods, :ordinal, unique: true, where: 'ordinal IS NOT NULL', name: 'rsc_arcade_season_number'
    add_check_constraint :discourse_rsc_arcade_periods,
      "game IS NULL OR (starts_at IS NOT NULL AND starts_at < ends_at AND ordinal IS NOT NULL AND ordinal > 0 AND cadence IS NOT NULL AND cadence IN ('weekly','daily'))",
      name: 'rsc_arcade_season_valid'
    add_index :discourse_rsc_arcade_runs, [:game, :user_id, :score], where: "status = 'finished'", name: 'rsc_arcade_all_time'
  end
end
