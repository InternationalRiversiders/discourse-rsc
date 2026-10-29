# frozen_string_literal: true
module DiscourseRsc
  class Instrument < ActiveRecord::Base
    self.table_name = "discourse_rsc_instruments"
    attribute :minimum_units, :decimal, precision: 78
    attribute :step_units, :decimal, precision: 78
    after_commit :invalidate_catalog

    def display_symbol
      metadata['display_symbol'].presence || symbol.to_s.split(':', 2).last
    end

    def exchange
      metadata['exchange'].presence || (symbol.include?(':') ? symbol.split(':', 2).first : nil)
    end

    def self.catalog_summary
      { total: count, active: where(active: true).count, inactive: where(active: false).count }
    end

    def invalidate_catalog
      fields = %w[symbol name category currency provider provider_symbol metadata active fee_bps minimum_units step_units]
      return unless destroyed? || (previous_changes.keys & fields).any?
      Rails.cache.delete('rsc:market:catalog:v1')
      Discourse.cache.delete('rsc:trading-hours')
    end

    validates :symbol, :name, presence: true
    validates :fee_bps, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1000 }
  end
end
