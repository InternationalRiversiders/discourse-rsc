# frozen_string_literal: true
module DiscourseRsc
  class MarketRequest < ActiveRecord::Base
    self.table_name = "discourse_rsc_market_requests"

    def self.present(rows)
      aliases = rows.to_h do |row|
        codes = Catalog.identifiers(row['symbol']).last rescue [row['symbol']]
        [row['id'], codes]
      end
      codes = aliases.values.flatten.uniq
      columns = Instrument.column_names - %w[quote history]
      items = Instrument.where(symbol: codes).or(Instrument.where(provider_symbol: codes)).select(*columns).to_a
      canonical_ids = items.filter_map { |i| i.metadata['canonical_instrument_id'] }
      items += Instrument.where(id: canonical_ids).select(*columns).to_a if canonical_ids.any?
      rows.map do |row|
        matches = items.select { |i| aliases[row['id']].include?(i.symbol) || aliases[row['id']].include?(i.provider_symbol) }
        item = matches.min_by { |i| [i.active? ? 0 : 1, i.id] }
        state = if item; item.active? ? 'listed' : 'inactive'
          elsif row.dig('details', 'last_error_code').present?; 'failed'
          elsif row['status'] == 'rejected'; 'rejected'
          else 'unlisted'; end
        label = {'listed'=>'已收录', 'inactive'=>'已停用', 'failed'=>'校验失败', 'rejected'=>'历史拒绝', 'unlisted'=>'待校验'}[state]
        row.merge('listing_status'=>state, 'listing_status_label'=>label, 'name'=>item&.name,
          'resolved_instrument_id'=>item&.id, 'listing_error'=>(state == 'failed' ? row.dig('details', 'last_error') : nil), 'can_retry'=>%w[failed unlisted rejected].include?(state))
      end
    end
  end
end
