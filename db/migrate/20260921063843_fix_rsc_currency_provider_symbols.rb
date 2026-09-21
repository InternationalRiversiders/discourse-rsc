# frozen_string_literal: true
class FixRscCurrencyProviderSymbols < ActiveRecord::Migration[7.2]
  def up
    # A unit of foreign currency is priced in USD/RSC. XXX=X is the inverse
    # USD/XXX pair; changing only the default adapter preserves the asset unit.
    execute <<~SQL
      UPDATE discourse_rsc_instruments
      SET provider_symbol=substring(symbol from 4) || 'USD=X'
      WHERE provider='yahoo' AND symbol ~ '^FX:[A-Z]{3}$'
        AND provider_symbol=substring(symbol from 4) || '=X'
    SQL
  end
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
