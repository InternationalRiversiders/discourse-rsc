# frozen_string_literal: true
class AddRscDividendSourceTracking < ActiveRecord::Migration[7.2]
  def change
    add_column :discourse_rsc_dividends, :source, :string, null: false, default: 'manual'
    add_column :discourse_rsc_dividends, :source_checked_at, :datetime
    add_column :discourse_rsc_dividends, :source_issue, :string
  end
end
