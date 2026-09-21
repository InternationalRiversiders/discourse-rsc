# frozen_string_literal: true
# Read-only, row-by-row verification in the guarded isolated rehearsal database.
isolated = ENV['RSC_DISPOSABLE_CONTAINER'] == '1' && %w[rsc_discourse_smoke rsc_readiness_snapshot rsc_full_rehearsal].include?(GlobalSetting.db_name)
path = ARGV.fetch(0)
production_check = ENV['RSC_VERIFY_CUTOVER_SHA256'].present? &&
  Digest::SHA256.file(path).hexdigest == ENV['RSC_VERIFY_CUTOVER_SHA256'] &&
  !SiteSetting.rsc_enabled && SiteSetting.rsc_read_only
abort 'isolated database or disabled read-only cutover with matching checksum required' unless isolated || production_check
R=DiscourseRsc
payload=JSON.parse(File.read(path))
ActiveRecord::Base.transaction do
ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')
t=payload.fetch('tables')
def check(value, name)
  raise "reconciliation_failed: #{name}" unless value
end
def units(value)
  R::Amount.parse(value)
end
checks={}
source_rows=0
t.each do |table,rows|
  expected=rows.each_with_index.to_h { |row,index| [(row['id'] || index).to_s,row] }
  check(expected.size==rows.size,"source keys #{table}")
  scope=R::LegacyRecord.where(source_table:table)
  check(scope.count==rows.size,"archive count #{table}")
  scope.find_each(batch_size:1000) { |record| check(record.data==expected.fetch(record.source_id),"archive contents #{table}") }
  source_rows+=rows.size
end
checks[:all_archived_rows_match_source]=source_rows
wallets=R::Account.where(kind:'wallet').index_by(&:user_id)
quarantined=R::Account.where("key LIKE 'legacy-quarantine:%'").index_by { |a| a.key.split(':').last.to_i }
check(wallets.size+quarantined.size==t.fetch('point_accounts').size,'wallet count')
t.fetch('point_accounts').each do |row|
  id=row.fetch('discourse_user_id')
  wallet=wallets[id] || quarantined.fetch(id)
  check(wallet.balance_units.to_i==units(row.fetch('balance_rsc')),'wallet exact balance')
  expected_status=quarantined.key?(id) ? 'frozen' : (row.fetch('status')=='active' ? 'active' : 'frozen')
  check(wallet.status==expected_status,'wallet state')
  check(wallet.user_id.nil? && !User.exists?(id:id),'orphan ownership retained') if quarantined.key?(id)
end
checks[:wallets_with_exact_balances]=wallets.size
checks[:quarantined_wallets_with_exact_balances]=quarantined.size
instruments=R::Instrument.all.index_by(&:symbol)
source_instruments=t.fetch('market_instruments').to_h { |row| [row.fetch('id'),instruments.fetch(row.fetch('symbol'))] }
check(instruments.size==source_instruments.size,'instrument count')
check(instruments.values.all? { |instrument| instrument.quote.empty? || instrument.quote['legacy_snapshot'] == true },'legacy quotes never marked fresh')
checks[:archived_quotes_for_display]=instruments.values.count { |instrument| instrument.quote['legacy_snapshot'] }
checks[:archived_candles_for_display]=R::HistoryCache.where(source: 'legacy').sum(Arel.sql('jsonb_array_length(candles)'))
checks[:instruments]=instruments.size
positions=R::Position.all.index_by { |row| [row.user_id,row.instrument_id] }
active=t.fetch('positions').select { |row| units(row.fetch('quantity')).positive? }
check(positions.size==active.size,'active position count')
active.each do |row|
  position=positions.fetch([row.fetch('discourse_user_id'),source_instruments.fetch(row.fetch('instrument_id')).id])
  %w[quantity margin].each { |field| check(position.public_send(field+'_units').to_i==units(row.fetch(field=='quantity' ? field : field+'_rsc')),'position '+field) }
  check(position.average_units.to_i==units(row.fetch('average_price_rsc')),'position entry price')
  check(position.side==row.fetch('side') && position.leverage==row.fetch('leverage'),'position direction/leverage')
  %w[take_profit stop_loss].each { |field| expected=row[field+'_price_rsc']; actual=position.public_send(field+'_units'); check(expected.nil? ? actual.nil? : actual.to_i==units(expected),'position protection') }
  check(R::Account.find_by!(key:"position:#{position.id}").balance_units.to_i==position.margin_units.to_i,'position escrow')
end
checks[:active_positions]=positions.size
orders=R::Order.all.index_by { |order| order.details.fetch('legacy_id') }
check(orders.size==t.fetch('exchange_orders').size,'order count')
t.fetch('exchange_orders').each do |row|
  order=orders.fetch(row.fetch('id'))
  status={'pending'=>'canceled','cancelled'=>'canceled','liquidated'=>'filled'}.fetch(row['status'],row['status'])
  check(order.status==status,'order status')
  check(order.quantity_units.to_i==units(row.fetch('quantity')),'order quantity')
  check(order.details['pnl']==row['pnl_rsc'] && order.details['fee']==row['fee_rsc'],'order financial history')
end
checks[:orders]=orders.size
matches=R::SportMatch.all.index_by(&:external_id)
source_matches=t.fetch('world_cup_matches').to_h { |row| [row.fetch('id'),matches.fetch(row.fetch('external_id'))] }
check(matches.size==source_matches.size,'match count')
predictions=R::Prediction.all.index_by { |row| [row.user_id,row.sport_match_id] }
check(predictions.size==t.fetch('world_cup_predictions').size,'prediction count')
t.fetch('world_cup_predictions').each do |row|
  prediction=predictions.fetch([row.fetch('discourse_user_id'),source_matches.fetch(row.fetch('match_id')).id])
  check(prediction.stake_units.to_i==units(row.fetch('stake_rsc')) && prediction.payout_units.to_i==units(row.fetch('payout_rsc')),'prediction money')
  check(prediction.status==row.fetch('status') && prediction.pick==row.fetch('pick') && prediction.odds==row.fetch('odds_decimal'),'prediction state and locked odds')
  if prediction.status=='pending'
    check(R::Account.find_by!(key:"prediction:#{prediction.id}").balance_units.to_i==prediction.stake_units.to_i,'prediction escrow')
  end
end
checks[:matches]=matches.size;checks[:predictions]=predictions.size
packets=R::Packet.all.index_by(&:token)
check(packets.size==t.fetch('rsc_red_packets').size,'packet count')
t.fetch('rsc_red_packets').each do |row|
  packet=packets.fetch(row.fetch('public_token'))
  check(packet.total_units.to_i==units(row.fetch('total_rsc')),'packet total')
  claims=t.fetch('rsc_red_packet_claims').select { |claim| claim.fetch('packet_id')==row.fetch('id') }.sort_by { |claim| claim['id'] }
  actual=packet.claims.order(:id).map { |claim| [claim.user_id,claim.units.to_i] }
  check(actual==claims.map { |claim| [claim.fetch('recipient_discourse_user_id'),units(claim.fetch('amount_rsc'))] },'packet claims')
  if packet.status=='open'
    balance=R::Account.find_by!(key:"packet:#{packet.id}").balance_units.to_i
    check(balance==units(row.fetch('remaining_rsc')),'packet remaining escrow')
    check(packet.allocations.drop(actual.size).sum(&:to_i)==balance,'packet unclaimed allocation')
  end
end
checks[:packets]=packets.size;checks[:packet_claims]=R::PacketClaim.count
reward_keys=R::Command.where("key LIKE 'daily_reward:%'").pluck(:key).to_set
rewards=t.fetch('reward_payouts').select { |row| row['status']=='success' }
check(rewards.size==reward_keys.size,'reward marker count')
rewards.each { |row| check(reward_keys.include?("daily_reward:#{row['discourse_user_id']}:daily-#{row['date']}"),'reward replay prevention') }
checks[:reward_markers]=rewards.size
tip_groups=t.fetch('post_tips',[]).group_by { |row| row.fetch('post_id') }
tip_groups.each do |post_id, rows|
  report=R::Reports.post_tips(Struct.new(:id).new(post_id))
  check(report[:count]==rows.size,'post tip display count')
  check(units(report[:total])==rows.sum { |row| units(row.fetch('amount_rsc')) },'post tip display amount')
end
checks[:post_tip_groups]=tip_groups.size
check(R::Entry.sum(:units).zero?,'global double entry balance')
check(R::Entry.group(:journal_id).having('SUM(units) <> 0').count.empty?,'per journal double entry balance')
entry_totals=R::Entry.group(:account_id).sum(:units)
R::Account.find_each { |account| check(account.balance_units.to_i==entry_totals.fetch(account.id,0).to_i,'account ledger balance') }
check(R::Event.count.zero?,'no historical notifications replayed')
check((!SiteSetting.rsc_enabled || R::Safety.read_only?) && !SiteSetting.rsc_market_data_enabled && !SiteSetting.rsc_sports_data_enabled && !SiteSetting.rsc_daily_rewards_enabled,'all production jobs disabled')
checks[:balanced_accounts]=R::Account.count
checks[:historical_notifications_generated]=R::Event.count
puts JSON.pretty_generate({status:'passed',scope:payload.key?('rehearsal_subset') ? 'resolved_account_subset_only' : 'complete_export',checks:checks,requires_identity_resolution:payload.key?('rehearsal_subset'),production_cutover:!isolated})

end
