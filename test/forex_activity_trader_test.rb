# frozen_string_literal: true
require '/rsc/test/forex_activity_test'

class ForexActivityTraderTest < ForexActivityTest
  ForexActivityTest.instance_methods.grep(/^test_/).each { |name| undef_method name }

  def test_activity_detail_excludes_old_fx_stocks_other_users_and_wallet
    travel_to(Time.utc(2026,10,22,12)) do
      fund; old = forex('FX:CNY'); submit(old, leverage: 1)
      travel 2.minutes
      activity
      submit(old, leverage: 1); tick_quote(old) # Adding to a pre-activity position is not eligible.
      fx = forex('FX:BRL'); opening = submit(fx); tick_quote(fx)
      stock = instrument('1'); submit(stock, leverage: 1)
      closing = submit(fx, side: 'close', quantity: '20')
      assert_nil closing.details['forex_campaign']
      fund(@bob)
      R::Exchange.submit(actor: @bob, instrument_id: fx.id, side: 'long', quantity: '10', leverage: 1, request_id: SecureRandom.uuid)
      tick_quote(fx)
      result = R::ForexActivityTrader.show(@alice.id)
      assert_equal ['FX:BRL'], result[:rows].map { |row| row[:symbol] }
      assert_equal '80', result[:rows].first[:quantity]
      assert_equal 'BRL', result[:rows].first[:display_symbol]
      assert_equal 2, result[:summary][:trade_count]
      assert_equal 1, result[:summary][:position_count]
      refute result[:summary].key?(:balance)
      refute result[:summary].key?(:equity)
      refute result[:rows].first.key?(:take_profit)
      records = R::ForexActivityTrader.show(@alice.id, section: 'orders')
      assert_equal [closing.id, opening.id], records[:rows].map { |row| row[:id] }
      assert records[:rows].all? { |row| row[:executed_at] }
      assert_equal 0, R::Entry.sum(:units)
    end
  end

  def test_activity_detail_uses_settlement_time_and_excludes_post_event_closes
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; fx = forex; opening = submit(fx); tick_quote(fx)
      opening.update!(created_at: 1.day.ago) # An earlier submission still has an in-window fill.
      before = R::ForexActivityTrader.show(@alice.id, section: 'orders')
      assert_equal [opening.id], before[:rows].map { |row| row[:id] }
      SiteSetting.rsc_forex_activity_ends_at = 2.seconds.from_now.iso8601
      travel 3.seconds
      fx.update!(quote: quote('1'))
      submit(fx, side: 'close')
      after = R::ForexActivityTrader.show(@alice.id, section: 'orders')
      assert_equal [opening.id], after[:rows].map { |row| row[:id] }
      assert_empty R::ForexActivityTrader.show(@alice.id)[:rows]
    end
  end

  def test_activity_detail_includes_liquidation_and_paginates_completed_trades
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; fx = forex
      11.times { submit(fx, quantity: '1'); tick_quote(fx); submit(fx, side: 'close', quantity: '1') }
      submit(fx, quantity: '1'); tick_quote(fx); tick_quote(fx, '0.99')
      first = R::ForexActivityTrader.show(@alice.id, section: 'orders')
      assert_equal 24, first[:pagination][:total]
      assert_equal 20, first[:rows].size
      assert_equal 'stock_liquidated', first[:rows].first[:reason]
      second = R::ForexActivityTrader.show(@alice.id, section: 'orders', page: 2)
      assert_equal 4, second[:rows].size
      assert_empty(first[:rows].map { |row| row[:id] } & second[:rows].map { |row| row[:id] })
      assert_equal 'invalid_page', assert_raises(R::Error) { R::ForexActivityTrader.show(@alice.id, page: 0) }.code
      assert_equal 'invalid_section', assert_raises(R::Error) { R::ForexActivityTrader.show(@alice.id, section: 'predictions') }.code
    end
  end

  def test_activity_detail_http_requires_membership_and_available_target
    travel_to(Time.utc(2026,10,22,12)) do
      fund; activity; fx = forex; submit(fx); tick_quote(fx)
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host! 'rsc.test'; session.https!
      endpoint = "/rsc/forex-activity/traders/#{@alice.id}.json"
      session.get endpoint
      refute_equal 200, session.response.status
      stranger = make_user('fx_outsider')
      key = ApiKey.create!(user: stranger, description: 'isolated activity privacy')
      session.get endpoint, headers: { 'Api-Key'=>key.key, 'Api-Username'=>stranger.username }
      assert_equal 403, session.response.status
      key = ApiKey.create!(user: @bob, description: 'isolated activity member')
      headers = { 'Api-Key'=>key.key, 'Api-Username'=>@bob.username }
      session.get endpoint, headers: headers
      assert_equal 200, session.response.status, session.response.body
      assert_equal 'FX:JPY', JSON.parse(session.response.body).dig('rows', 0, 'symbol')
      session.get "/rsc/forex-activity/traders/#{@bob.id}.json", headers: headers
      assert_equal 404, session.response.status
      R::Account.wallet(@alice.id).update!(status: 'frozen')
      session.get endpoint, headers: headers
      assert_equal 404, session.response.status
    ensure
      ApiKey.where(description: ['isolated activity privacy', 'isolated activity member']).destroy_all
    end
  end
end
