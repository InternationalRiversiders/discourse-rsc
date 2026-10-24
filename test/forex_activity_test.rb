# frozen_string_literal: true
require '/rsc/test/business_test'
require 'active_support/testing/time_helpers'

class ForexActivityTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }
  include ActiveSupport::Testing::TimeHelpers

  def setup
    super
    UserBadge.where(badge_id: Badge.where(name: R::ForexActivity::BADGES.values.map(&:first)).select(:id)).delete_all
  end
  def activity
    SiteSetting.rsc_forex_activity_enabled = true
    SiteSetting.rsc_forex_activity_starts_at = 1.minute.ago.iso8601
    SiteSetting.rsc_forex_activity_ends_at = 14.days.from_now.iso8601
    SiteSetting.rsc_high_risk_enabled = true
  end
  def forex(symbol='FX:JPY')
    item = instrument('1')
    item.update!(symbol: symbol, category: 'forex', asset_type: 'forex', fee_bps: 5,
      minimum_units: R::Amount.parse('0.01'), step_units: R::Amount.parse('0.01'))
    item
  end
  def submit(item, side: 'long', quantity: '100', leverage: 100, request_id: SecureRandom.uuid)
    result = R::Exchange.submit(actor: @alice, instrument_id: item.id, side: side,
      quantity: quantity, leverage: leverage, high_risk: leverage > 10, request_id: request_id)
    R::Order.find(result['order_id'])
  end
  def tick_quote(item, price='1')
    travel 1.second
    at = Time.current.iso8601(6)
    item.update!(quote: quote(price), history: item.history + [{ 'at'=>at, 'price'=>price }])
    R::Exchange.process(item.id)
  end
  def entry; R::ForexActivityEntry.first!; end
  def test_activity_bounds_and_category_scope
    travel_to(Time.utc(2026,10,22,12)) do
      item=forex; activity
      assert R::ForexActivity.active_for?(item)
      other=instrument; refute R::ForexActivity.active_for?(other)
      assert_equal 100,R::MarketListing.rows([item]).first[:max_leverage]
      assert_equal 'forex_confirmation',R::MarketListing.rows([item]).first[:execution_mode]
      travel_to R::ForexActivity.ends_at
      refute R::ForexActivity.active?
      assert_equal 10,R::MarketListing.rows([item]).first[:max_leverage]
      assert_equal 5,R::ForexActivity.fee_bps(item)
      assert_equal false,R::MarketListing.rows([item]).first[:margin_budget_exempt]
    end
  end
  def test_new_quote_confirmation_fee_and_idempotence
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; item=forex
      order=submit(item,request_id:'fx-same-request')
      assert_equal 'pending',order.status
      assert_equal 1,order.details['fee_bps']
      R::Exchange.process(item.id)
      assert_equal 'pending',order.reload.status
      assert_equal 0,R::ForexActivityEntry.count
      tick_quote(item)
      assert_equal 'filled',order.reload.status
      assert_equal '0.01',order.details['fee']
      assert_equal -R::Amount.parse('0.01'),entry.realized_units.to_i
      assert_equal -R::Amount.parse('0.02'),entry.realized_units.to_i+entry.mark_units.to_i
      assert_equal order.id,submit(item,request_id:'fx-same-request').id
      assert_equal 1,R::ForexActivityEntry.count
      assert_equal 0,R::Entry.sum(:units)
    end
  end
  def test_partial_and_full_close_net_matches_wallet_and_fee
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; item=forex
      submit(item); tick_quote(item)
      tick_quote(item,'1.002');closing=submit(item,side:'close',quantity:'40')
      assert_equal 'filled',closing.reload.status
      refute entry.closed_at
      tick_quote(item,'1.003');closing=submit(item,side:'close',quantity:'60')
      assert_equal 'filled',closing.reload.status
      assert_equal 0,R::Position.count
      assert entry.closed_at
      assert_equal 0,entry.mark_units.to_i
      assert_equal R::Account.wallet(@alice.id).balance_units.to_i-R::Amount.parse('1000'),entry.realized_units.to_i
      assert_equal '0.006018',closing.details['fee']
      assert_equal 0,R::Entry.sum(:units)
    end
  end
  def test_old_positions_not_counted_or_discounted
    travel_to(Time.utc(2026,10,22,12)) do
      fund; item=forex
      submit(item,leverage:5)
      assert_equal 1,R::Position.count
      activity
      assert_equal 5,R::MarketListing.rows([item],user_id:@alice.id).first[:fee_bps]
      extra=submit(item,leverage:5);tick_quote(item)
      assert_equal '0.05',extra.reload.details['fee']
      assert_equal 0,R::ForexActivityEntry.count
      submit(item,side:'close',quantity:'200');tick_quote(item)
      submit(item);tick_quote(item)
      assert_equal 1,R::ForexActivityEntry.count
      assert_equal 1,R::MarketListing.rows([item],user_id:@alice.id).first[:fee_bps]
    end
  end
  def test_forex_does_not_consume_crypto_budget_and_has_no_cooldown
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; coin=instrument('1');coin.update!(symbol:'COIN',category:'crypto',quote:quote('1').merge('bid'=>'1','ask'=>'1'))
      submit(coin,quantity:'20000');tick_quote(coin)
      crypto_used=R::Risk.high_risk_status(@alice.id)[:budget][:used_margin]
      fx=forex
      opening=submit(fx,quantity:'6000');tick_quote(fx)
      assert_equal 'filled',opening.reload.status
      assert_equal crypto_used,R::Risk.high_risk_status(@alice.id)[:budget][:used_margin]
      assert_equal 'insufficient_balance',assert_raises(R::Error) { submit(fx,quantity:'100000') }.code
      assert_equal true,R::MarketListing.rows([fx],user_id:@alice.id).first[:margin_budget_exempt]
      remaining=R::Risk.high_risk_status(@alice.id)[:budget][:available_margin]
      assert_operator BigDecimal(remaining),:<,50
      R::Order.create!(user_id:@alice.id,instrument_id:coin.id,side:'close',status:'filled',leverage:100,quantity_units:R::Amount.parse('1'))
      assert R::Risk.high_risk_cooldown_until(@alice.id)
      opening=submit(fx);tick_quote(fx)
      assert_equal 'filled',opening.reload.status
      refute R::Risk.hold_until(R::Position.find_by!(instrument_id:fx.id))
    end
  end
  def test_deadline_expires_pending_and_preserves_existing_exits
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; item=forex
      submit(item);tick_quote(item)
      position=R::Position.first!; pending=submit(item)
      ending=5.seconds.from_now
      SiteSetting.rsc_forex_activity_ends_at=ending.iso8601
      before=entry.realized_units.to_i+entry.mark_units.to_i
      travel_to ending+1.second
      tick_quote(item,'1.001')
      assert_equal 'expired',pending.reload.status
      assert_equal 'forex_activity_ended',pending.details['error']
      assert_raises(R::Error) { submit(item) }
      R::Exchange.add_margin(actor:@alice,position_id:position.id,amount:'1',request_id:SecureRandom.uuid)
      assert_equal before,entry.final_units.to_i
      R::Exchange.protect(actor:@alice,position_id:position.id,take_profit:'1.01',stop_loss:nil,request_id:SecureRandom.uuid)
      tick_quote(item,'1.002');closing=submit(item,side:'close')
      assert_equal 'filled',closing.reload.status
      assert_equal '0.01002',closing.details['fee']
      assert_equal before,entry.final_units.to_i
      assert_equal 0,R::Position.count
      assert_equal 0,R::Entry.sum(:units)
    end
  end
  def test_deadline_freezes_before_low_leverage_addition_and_ignores_future_history
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; item=forex
      submit(item,leverage:5);tick_quote(item)
      ending=5.seconds.from_now;SiteSetting.rsc_forex_activity_ends_at=ending.iso8601
      before=entry.realized_units.to_i+entry.mark_units.to_i
      travel_to ending+1.second
      tick_quote(item,'1.1')
      extra=submit(item,quantity:'100',leverage:5)
      assert_equal 'filled',extra.status
      assert_equal before,entry.final_units.to_i
      assert_equal R::Amount.parse('200'),R::Position.first.quantity_units
      R::ForexActivity.tick
      assert_equal before,entry.final_units.to_i
    end
  end
  def test_cancellation_never_counts_and_is_available_after_ten_seconds
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;item=forex
      pending=submit(item);travel 20.seconds
      R::Exchange.cancel(actor:@alice,order_id:pending.id,request_id:SecureRandom.uuid)
      assert_equal 'canceled',pending.reload.status
      assert_equal '1000',R::Account.wallet(@alice.id).balance
      assert_equal 0,R::ForexActivityEntry.count
    end
  end
  def test_awards_are_automatic_nonduplicating_and_final_scores_include_costs
    travel_to(Time.utc(2026,10,20,12)) do
      fund;activity;item=forex
      3.times do |n|
        travel 1.day if n>0
        item.update!(quote:quote('1'))
        submit(item,leverage:5);tick_quote(item)
      end
      tick_quote(item,'1.01');close=submit(item,side:'close',quantity:'300')
      assert_equal 'filled',close.reload.status
      assert_equal 3,entry.trade_days.size
      SiteSetting.rsc_forex_activity_ends_at=1.second.ago.iso8601
      R::ForexActivity.tick
      badges=Badge.where(name:R::ForexActivity::BADGES.values.map(&:first))
      assert_equal 3,UserBadge.where(user_id:@alice.id,badge_id:badges.select(:id)).count
      assert badges.all?(&:allow_title)
      R::ForexActivity.tick
      assert_equal 3,UserBadge.where(user_id:@alice.id,badge_id:badges.select(:id)).count
      result=R::ForexActivity.presentation(user_id:@alice.id)
      assert_equal 1,result[:me][:rank]
      assert_equal @alice.username,result[:me][:forum_user][:username]
      assert_equal 3,result[:me][:days]
      assert_equal true,result[:me][:final]
    end
  end
  def test_liquidation_cannot_earn_survivor_badge
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;item=forex
      submit(item);tick_quote(item);tick_quote(item,'0.99')
      assert_equal 0,R::Position.count
      assert entry.liquidated
      SiteSetting.rsc_forex_activity_ends_at=1.second.ago.iso8601
      R::ForexActivity.tick
      assert_operator entry.final_units.to_i,:<,0
      survivor=Badge.find_by(name:R::ForexActivity::BADGES[:survivor].first)
      refute UserBadge.exists?(user_id:@alice.id,badge_id:survivor.id)
    end
  end
  def test_http_activity_schedule_requires_admin_and_exposes_effective_policy
    travel_to(Time.utc(2026,10,22,12)) do
      activity;fund;item=forex
      session=ActionDispatch::Integration::Session.new(Rails.application)
      session.host! 'rsc.test';session.https!
      key=ApiKey.create!(user_id:@alice.id,created_by_id:@admin.id,description:'isolated FX member')
      headers={'Api-Key'=>key.key,'Api-Username'=>@alice.username}
      session.get '/rsc/state.json',params:{section:'market',market_category:'fx_activity'},headers:headers
      assert_equal 200,session.response.status,session.response.body
      state=JSON.parse(session.response.body)
      assert_equal true,state.dig('forex_activity','active')
      assert_equal 'forex',state.dig('market_page','category')
      refute_includes state.dig('market_page','categories'),'fx_activity'
      assert_equal 100,state.dig('market_page','rows',0,'max_leverage')
      assert_equal 1,state.dig('market_page','rows',0,'fee_bps')
      session.get '/rsc/forex-activity.json',headers:headers
      assert_equal 200,session.response.status
      assert_equal [],JSON.parse(session.response.body)['rows']
      session.post '/rsc/forex-activity/settings.json',params:{ends_at:3.days.from_now.iso8601},headers:headers
      assert_equal 403,session.response.status
      key=ApiKey.create!(user_id:@admin.id,created_by_id:@admin.id,description:'isolated FX admin')
      headers={'Api-Key'=>key.key,'Api-Username'=>@admin.username}
      ending=Time.utc(2026,12,17,18)
      session.post '/rsc/forex-activity/settings.json',params:{ends_at:ending.iso8601},headers:headers
      assert_equal 200,session.response.status,session.response.body
      assert_equal ending,R::ForexActivity.ends_at
      assert R::Audit.exists?(action:'forex_activity_schedule',actor_user_id:@admin.id)
      session.post '/rsc/forex-activity/settings.json',params:{ends_at:'not a date'},headers:headers
      assert_equal 422,session.response.status
      assert_equal ending,R::ForexActivity.ends_at
    end
  end
  def test_activity_refresh_stays_within_existing_batch_budget
    travel_to(Time.utc(2026,10,22,12)) do
      activity
      R::ForexActivity::FEATURED.each { |symbol| item=forex(symbol);item.update!(provider:'yahoo') }
      cold=forex('FX:INR');cold.update!(provider:'yahoo')
      SiteSetting.rsc_market_data_enabled=true
      previous_batch=SiteSetting.rsc_market_sync_batch
      SiteSetting.rsc_market_sync_batch=2
      calls=[]
      due=R::MarketData.method(:refresh_due?);refresh=R::MarketData.method(:refresh_if_needed)
      R::MarketData.define_singleton_method(:refresh_due?) { |*| true }
      R::MarketData.define_singleton_method(:refresh_if_needed) { |id,**| calls << id;R::Instrument.find(id) }
      R::MarketData.sync
      assert_equal 2,calls.size
      refute_includes calls,cold.id
    ensure
      SiteSetting.rsc_market_sync_batch=previous_batch if previous_batch
      R::MarketData.define_singleton_method(:refresh_due?,due) if due
      R::MarketData.define_singleton_method(:refresh_if_needed,refresh) if refresh
    end
  end

  def test_deadline_releases_reservations_without_fresh_quote_or_execute_time
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;item=forex
      order=submit(item);order.update!(execute_at:10.minutes.from_now)
      SiteSetting.rsc_forex_activity_ends_at=1.second.ago.iso8601
      item.update!(quote:{})
      R::Exchange.process(item.id)
      assert_equal 'expired',order.reload.status
      assert_equal 'forex_activity_ended',order.details['error']
      assert_equal '1000',R::Account.wallet(@alice.id).balance
      assert_equal 0,R::Entry.sum(:units)
    end
  end

  def awarded_keys
    R::ForexActivity::BADGES.keys.select do |key|
      badge = Badge.find_by!(name: R::ForexActivity::BADGES[key].first)
      UserBadge.exists?(user_id: @alice.id, badge_id: badge.id)
    end
  end

  def test_profit_thresholds_use_realized_net_and_remember_reversed_profit
    travel_to(Time.utc(2026,10,22,12)) do
      fund(@alice, '10000'); activity; item=forex
      submit(item, quantity:'1000', leverage:5); tick_quote(item)
      tick_quote(item, '2.1'); R::ForexActivity.award
      assert_equal [:debut], awarded_keys # floating profit is not an achievement
      submit(item, side:'close', quantity:'1000'); tick_quote(item, '2.1')
      # Lose more than the realized profit before the next badge job runs.
      item.update!(quote:quote('1'))
      submit(item, quantity:'6000', leverage:5); tick_quote(item)
      tick_quote(item, '0.79')
      assert entry.class.where(liquidated:true).exists?
      assert_operator R::ForexActivity.entries.sum(:realized_units), :<, 0
      wallet = R::Account.wallet(@alice.id).balance
      2.times { R::ForexActivity.award }
      assert_includes awarded_keys, :profit_100
      assert_includes awarded_keys, :profit_1000
      assert_includes awarded_keys, :liquidated
      assert_includes awarded_keys, :loss_100
      refute_includes awarded_keys, :loss_1000 # aggregate net, not sum of losing trades
      assert_equal wallet, R::Account.wallet(@alice.id).balance
      assert_equal awarded_keys.size, UserBadge.where(user_id:@alice.id, badge_id:Badge.where(name:R::ForexActivity::BADGES.values.map(&:first)).select(:id)).count
    end
  end

  def test_loss_milestones_survive_recovery_and_ignore_after_deadline_profit
    travel_to(Time.utc(2026,10,22,12)) do
      fund(@alice, '10000'); activity; item=forex
      submit(item, quantity:'6000', leverage:5); tick_quote(item); tick_quote(item,'0.79')
      item.update!(quote:quote('1'))
      submit(item, quantity:'2000', leverage:5); tick_quote(item)
      tick_quote(item,'1.7')
      closing=submit(item, side:'close', quantity:'2000'); tick_quote(item,'1.7')
      assert_equal 'filled',closing.reload.status
      R::ForexActivity.award
      assert_includes awarded_keys, :loss_100
      assert_includes awarded_keys, :loss_1000
      assert_includes awarded_keys, :profit_100
      refute_includes awarded_keys, :profit_1000
      item.update!(quote:quote('1'))
      submit(item, quantity:'2000', leverage:5); tick_quote(item)
      SiteSetting.rsc_forex_activity_ends_at=1.second.from_now.iso8601
      travel 2.seconds
      tick_quote(item,'2')
      closing=submit(item, side:'close', quantity:'2000'); tick_quote(item,'2')
      assert_equal 'filled',closing.reload.status
      R::ForexActivity.tick
      refute_includes awarded_keys, :profit_1000
      refute_includes awarded_keys, :survivor
    end
  end

  def test_fee_boundary_old_positions_and_legacy_journals
    travel_to(Time.utc(2026,10,22,12)) do
      fund(@alice,'10000'); item=forex
      submit(item,quantity:'1000',leverage:5)
      activity
      tick_quote(item,'2')
      closing=submit(item,side:'close',quantity:'1000');tick_quote(item,'2')
      assert_equal 'filled',closing.reload.status
      assert_empty R::ForexActivity.realized_extremes
      item.update!(quote:quote('1'))
      # Simulate journals made by the old release, without position metadata.
      original=R::Commands.method(:move)
      R::Commands.define_singleton_method(:move) do |**args|
        args[:metadata] = args[:metadata].except(:position_id)
        original.call(**args)
      end
      submit(item,quantity:'1000',leverage:5);tick_quote(item)
      tick_quote(item,'1.1')
      closing=submit(item,side:'close',quantity:'1000');tick_quote(item,'1.1')
      assert_equal 'filled',closing.reload.status
      assert_operator R::ForexActivity.entries.sum(:realized_units), :<, R::Amount.parse('100')
      R::ForexActivity.award
      assert_equal [:debut], awarded_keys
      # Small extra realized gain crosses the net (after fees) boundary.
      item.update!(quote:quote('1'))
      submit(item,quantity:'100',leverage:5);tick_quote(item)
      tick_quote(item,'1.01');submit(item,side:'close',quantity:'100')
      R::ForexActivity.award
      assert_includes awarded_keys, :profit_100
      assert_equal R::ForexActivity.entries.sum(:realized_units).to_i, R::ForexActivity.realized_extremes[@alice.id][:max]
    ensure
      R::Commands.define_singleton_method(:move,original) if original
    end
  end

  def test_legacy_badges_rename_in_place_and_keep_selected_titles
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; item=forex
      submit(item);tick_quote(item)
      R::ForexActivity.award
      badge=Badge.find_by!(name:R::ForexActivity::BADGES[:debut].first)
      old_name=R::ForexActivity::LEGACY_BADGES[:debut]
      badge.update!(name:old_name)
      @alice.update!(title:old_name)
      @alice.user_profile.update!(granted_title_badge_id:badge.id)
      grant=UserBadge.find_by!(user_id:@alice.id,badge_id:badge.id)
      R::ForexActivity.award
      assert_equal old_name,badge.reload.name # safe while old workers still run
      2.times { R::ForexActivity.award(rename_legacy:true) }
      assert_equal R::ForexActivity::BADGES[:debut].first,badge.reload.name
      assert_equal badge.name,@alice.reload.title
      assert_equal grant.id,UserBadge.find_by!(user_id:@alice.id,badge_id:badge.id).id
      refute Badge.exists?(name:old_name)
    end
  end

end
