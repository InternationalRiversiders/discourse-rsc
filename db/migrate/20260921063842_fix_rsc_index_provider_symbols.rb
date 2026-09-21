# frozen_string_literal: true
class FixRscIndexProviderSymbols < ActiveRecord::Migration[7.2]
  def up
    # Repair only the former default mappings; preserve explicit admin overrides.
    { 'RUT'=>'^RUT', 'CSI300'=>'000300.SS', 'FTSE100'=>'^FTSE', 'CAC40'=>'^FCHI',
      'STOXX50'=>'^STOXX50E', 'ASX200'=>'^AXJO', 'KOSPI'=>'^KS11', 'STI'=>'^STI',
      'TSX'=>'^GSPTSE', 'NIFTY50'=>'^NSEI' }.each do |old, replacement|
      execute <<~SQL
        UPDATE discourse_rsc_instruments SET provider_symbol=#{connection.quote(replacement)}
        WHERE provider='yahoo' AND symbol=#{connection.quote("INDEX:#{old}")}
          AND provider_symbol=#{connection.quote(old)}
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
