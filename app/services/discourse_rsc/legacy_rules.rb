# frozen_string_literal: true
module DiscourseRsc
  module LegacyRules
    def self.restore!(during_import: false)
      raise Error.new('import_requires_disabled_plugin') if !during_import && SiteSetting.rsc_enabled && !Safety.read_only?
      result={instruments:0,positions:0,orders:0,requests:0,exemptions:0,packets:0}
      Instrument.transaction do
        Commands.lock('rsc-import')
        instruments=Instrument.all.index_by(&:symbol)
        mapping={}
        LegacyRecord.where(source_table:'market_instruments').pluck(:data).each do |row|
          item=instruments[row['symbol']];next unless item
          mapping[row['id'].to_s]=item
          if item.asset_type.blank? && row['asset_type'].present?;item.update!(asset_type:row['asset_type']);result[:instruments]+=1;end
        end
        legacy_orders=LegacyRecord.where(source_table:'exchange_orders').pluck(:data)
        legacy_by_id=legacy_orders.index_by { |row| row['id'].to_s }
        Order.where("details ? 'legacy_id'").find_each do |order|
          row=legacy_by_id[order.details['legacy_id'].to_s];next unless row
          reason = if row['status']=='liquidated'
            'stock_liquidated'
          elsif %w[take_profit stop_loss].include?(row['order_type'])
            "stock_#{row['order_type']}"
          elsif row['status']=='pending'
            'legacy_pending_canceled'
          elsif %w[sell cover close].include?(row['side']) && row['status']=='filled'
            'stock_closed'
          else
            'legacy_import'
          end
          details=order.details.merge('reason'=>reason).merge({'price'=>row['executed_price_rsc'],'gross'=>row['gross_rsc'],'fee'=>row['fee_rsc'],'margin'=>row['margin_rsc'],'pnl'=>row['pnl_rsc'],'error'=>row['error'],'reference_price'=>row['reference_price_rsc']}.compact)
          if details!=order.details;order.update_columns(details:details);result[:orders]+=1;end
        end
        order_index=legacy_orders.group_by { |r| [r['discourse_user_id'].to_i,mapping[r['instrument_id'].to_s]&.id,r.fetch('position_side',r['side']=='short' ? 'short' : 'long')] }
        Position.includes(:instrument).find_each do |position|
          rows=(order_index[[position.user_id,position.instrument_id,position.side]] || []).select { |r| r['status']=='filled' && %w[buy long short].include?(r['side']) }
          dates=rows.filter_map do |row|
            if position.instrument.category=='crypto';Time.iso8601(row.fetch('created_at'))+5.minutes
            elsif row['order_type']=='delayed_market';Time.iso8601(row.fetch('updated_at',row.fetch('created_at')))+2.minutes;end
          end
          hold=([position.hold_until]+dates).compact.max
          if hold && hold!=position.hold_until;position.update!(hold_until:hold);result[:positions]+=1;end
        end
        LegacyRecord.where(source_table:'point_accounts').pluck(:data).each do |row|
          wallet=Account.find_by(user_id:row['discourse_user_id'],kind:'wallet')
          wallet.update!(status_reason:row['ban_reason']) if wallet&.status=='frozen' && wallet.status_reason.blank?
        end
        LegacyRecord.where(source_table:'rsc_red_packets').pluck(:data).each do |row|
          packet=Packet.find_by(token:row['public_token']);next unless packet && packet.claim_limit.nil?
          packet.update!(claim_limit:row['max_claims'],minimum_units:Amount.parse(row['min_amount_rsc'] || row['amount_rsc'] || '0'),maximum_units:Amount.parse(row['max_amount_rsc'] || row['amount_rsc'] || '0'));result[:packets]+=1
        end
        LegacyRecord.where(source_table:'outgoing_limit_exemptions').pluck(:data).each do |row|
          next if Time.iso8601(row.fetch('expires_at'))<=Time.current
          item=Exemption.find_or_initialize_by(user_id:row['discourse_user_id'],expires_at:row['expires_at'])
          if item.new_record?;item.assign_attributes(reason:row['reason'].presence || 'Legacy exemption',actor_user_id:row['created_by_discourse_user_id'] || Discourse::SYSTEM_USER_ID);result[:exemptions]+=1;end
          item.starts_at ||= row['starts_at'];item.save!
        end
        # The old admin's add-request list is a GROUP BY over market_search_requests,
        # not a physical market_add_requests table. Preserve each user's request.
        groups=LegacyRecord.where(source_table:'market_search_requests').pluck(:data).select { |r| r['requested_symbol'].present? }.group_by { |r| [r['discourse_user_id'].to_i,r['requested_symbol'].strip.upcase] }
        groups.each do |(id,symbol),rows|
          next if MarketRequest.exists?(user_id:id,symbol:symbol)
          raise Error.new("import_missing_user_#{id}") unless User.exists?(id:id)
          latest=rows.max_by { |r| r['created_at'] }
          MarketRequest.create!(user_id:id,symbol:symbol,status:instruments.key?(symbol) ? 'approved' : 'pending',created_at:rows.map { |r| r['created_at'] }.min,updated_at:latest['created_at'],details:{legacy:true,request_count:rows.size,metadata:latest.slice('category','requested_name','requested_exchange','requested_currency','requested_asset_type','requested_display_symbol')})
          result[:requests]+=1
        end
      end
      result
    end
  end
end
