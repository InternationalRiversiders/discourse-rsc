# frozen_string_literal: true
require '/rsc/test/forex_activity_test'
require '/rsc/script/reset_forex_activity_user'

class ForexActivityResetTest < ForexActivityTest
  ForexActivityTest.instance_methods(false).grep(/^test_/).each { |name| undef_method name }

  def reset(apply: true, key: 'isolated-fx-reset')
    R::ForexActivityUserReset.run(user_id:@alice.id,reset_key:key,apply:apply)
  end

  def test_direct_reset_restores_cash_without_removing_unrelated_activity
    travel_to(Time.utc(2026,10,22,12)) do
      fund;fund(@bob,'200')
      stock=instrument('10');stock.update!(symbol:'STOCK')
      original=submit(stock,quantity:'1',leverage:1)
      baseline=R::Account.wallet(@alice.id).balance_units.to_i
      activity;fx=forex
      submit(fx,quantity:'100',leverage:5);tick_quote(fx)
      position=R::Position.find_by!(instrument_id:fx.id)
      R::Exchange.add_margin(actor:@alice,position_id:position.id,amount:'5',request_id:SecureRandom.uuid)
      submit(fx,side:'close',quantity:'100');tick_quote(fx,'1.01')
      fx.update!(quote:quote('1'))
      submit(fx,quantity:'100',leverage:5);tick_quote(fx)
      position=R::Position.find_by!(instrument_id:fx.id)
      R::Exchange.add_margin(actor:@alice,position_id:position.id,amount:'7',request_id:SecureRandom.uuid)
      submit(fx,quantity:'10',leverage:5) # reserved, not filled
      fund(@alice,'3')
      transfer=R::Wallet.transfer(actor:@alice,recipient:@bob,amount:'2',request_id:SecureRandom.uuid)
      R::ForexActivity.award
      badge=Badge.find_by!(name:R::ForexActivity::BADGES[:debut].first)
      @alice.update!(title:badge.name)
      @alice.user_profile.update!(granted_title_badge_id:badge.id)
      R::Event.where(kind:'stock_filled').find_each { |e| R::NotificationDelivery.deliver(e) }
      original_journals=R::Journal.where("metadata->>'order_id' = ?",original.id.to_s).pluck(:id)
      bob_balance=R::Account.wallet(@bob.id).balance
      counts=[R::Order.count,R::Journal.count,R::Entry.count]
      preview=reset(apply:false)
      assert preview['preview']
      assert_equal R::Amount.format(baseline+R::Amount.parse('1')),preview['wallet_after']
      assert_equal counts,[R::Order.count,R::Journal.count,R::Entry.count]
      fx_escrow_keys=R::ForexActivityEntry.pluck(:position_id).map { |id| "position:#{id}" } + R::Order.where(instrument_id:fx.id).pluck(:id).map { |id| "order:#{id}" }
      result=reset
      refute R::Account.where(key:fx_escrow_keys).exists?
      assert_equal preview['wallet_after'],R::Account.wallet(@alice.id).balance
      assert_equal bob_balance,R::Account.wallet(@bob.id).balance
      assert R::Journal.exists?(transfer.journal.id)
      assert_equal original_journals,R::Journal.where(id:original_journals).pluck(:id)
      assert R::Order.exists?(original.id)
      assert R::Position.exists?(instrument_id:stock.id,user_id:@alice.id)
      assert_equal 0,R::Order.where(instrument_id:fx.id).count
      assert_equal 0,R::ForexActivityEntry.count
      refute UserBadge.exists?(user_id:@alice.id,badge_id:badge.id)
      assert_nil @alice.reload.title
      assert_nil @alice.user_profile.reload.granted_title_badge_id
      assert_equal 0,R::Entry.sum(:units)
      R::Account.find_each do |a|
        assert_equal a.balance_units.to_i,R::Entry.where(account_id:a.id).sum(:units).to_i
        running=0
        R::Entry.where(account_id:a.id).order(:id).each { |e| running+=e.units.to_i;assert_equal running,e.balance_after_units.to_i }
      end
      R::ForexActivity.tick
      refute UserBadge.exists?(user_id:@alice.id,badge_id:badge.id)
      # Repeating the operation must not delete trades made after the reset.
      fx.update!(quote:quote('1'))
      opening=submit(fx,quantity:'100',leverage:5);tick_quote(fx)
      new_balance=R::Account.wallet(@alice.id).balance
      assert reset['already_applied']
      assert R::Order.exists?(opening.id)
      assert_equal new_balance,R::Account.wallet(@alice.id).balance
      assert_raises(ActiveRecord::StatementInvalid) { R::Entry.where(journal_id:transfer.journal.id).delete_all }
      assert_raises(ActiveRecord::StatementInvalid) { R::Journal.where(id:transfer.journal.id).update_all(metadata:{}) }
    end
  end

  def test_failure_after_deletion_restores_rows_balances_and_protection
    travel_to(Time.utc(2026,10,22,12)) do
      fund;activity;fx=forex
      submit(fx);tick_quote(fx)
      before=[R::Account.order(:id).pluck(:id,:balance_units),R::Journal.count,R::Entry.count,R::Order.count,R::Position.count,R::ForexActivityEntry.count]
      original=R::Audit.method(:create!)
      R::Audit.define_singleton_method(:create!) do |**args|
        raise 'forced final receipt failure' if args[:action]==R::ForexActivityUserReset::ACTION
        original.call(**args)
      end
      assert_equal 'forced final receipt failure',assert_raises(RuntimeError) { reset }.message
      assert_equal before,[R::Account.order(:id).pluck(:id,:balance_units),R::Journal.count,R::Entry.count,R::Order.count,R::Position.count,R::ForexActivityEntry.count]
      assert_raises(ActiveRecord::StatementInvalid) { R::Entry.where(id:R::Entry.first.id).delete_all }
      assert_raises(ActiveRecord::StatementInvalid) { R::Journal.where(id:R::Journal.first.id).update_all(metadata:{}) }
    ensure
      R::Audit.define_singleton_method(:create!,original) if original
    end
  end

  def test_reset_refuses_non_activity_forex_positions
    travel_to(Time.utc(2026,10,22,12)) do
      fund;fx=forex
      submit(fx,leverage:5)
      activity
      baseline=R::Account.wallet(@alice.id).balance
      assert_match(/Pre-activity/,assert_raises(RuntimeError) { reset }.message)
      assert_equal baseline,R::Account.wallet(@alice.id).balance
      assert_equal 1,R::Position.count
    end
  end
end
