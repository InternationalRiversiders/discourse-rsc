# frozen_string_literal: true
require_relative 'forecast_quote_errors_test'
require_relative 'forecast_combined_translation_test'

class ForecastTest
  def test_optional_reason_near_deadline_and_empty_book_do_not_block_listing
    raw = catalog_raw.merge('endDate' => 2.minutes.from_now.iso8601)
    catalog_provider(raw, empty_book: true) do
      result = R::ForecastListing.submit(actor: @alice, external_id: '901', reason: nil, request_id: SecureRandom.uuid)
      assert_equal 'pending', result['status']
      assert_equal '', R::ForecastRequest.first.reason
      review_catalog
      assert_equal 'approved', R::ForecastRequest.first.status
      assert_equal 'open', R::ForecastMarket.find_by!(external_id: '901').state
    end
  end

  def test_reapplication_after_one_hour_and_more_than_five_pending
    catalog_provider do
      request_catalog
      review_catalog('rejected')
      R::ForecastRequest.first.update!(updated_at: 61.minutes.ago)
      6.times { |i| R::ForecastRequest.create!(external_id: (960 + i).to_s, user_id: @alice.id, question: 'Test', terms_digest: 'test') }
      assert_equal 'pending', request_catalog['status']
    end
  end

  def test_portfolio_pagination_keeps_ownership_and_detail_holding
    markets = [@market] + 100.times.map do |i|
      row = @market.dup
      row.assign_attributes(external_id: (1000 + i).to_s, condition_id: '0x' + (1000 + i).to_s(16).rjust(64, '0'), slug: "page-market-#{i}")
      row.save!
      row
    end
    markets.each do |market|
      R::ForecastPosition.create!(market_id: market.id, user_id: @alice.id, outcome: 0, shares_units: R::Amount.parse('3'), cost_units: R::Amount.parse('1'))
    end
    R::ForecastPosition.create!(market_id: @market.id, user_id: @bob.id, outcome: 0, shares_units: R::Amount.parse('99'))
    31.times { R::ForecastTrade.create!(market_id: @market.id, user_id: @alice.id, outcome: 0, side: 'buy', shares_units: R::Amount.parse('2'), cash_units: R::Amount.parse('1')) }
    R::ForecastTrade.create!(market_id: @market.id, user_id: @bob.id, outcome: 0, side: 'buy', shares_units: R::Amount.parse('99'), cash_units: R::Amount.parse('1'))
    key = ApiKey.create!(user_id: @alice.id, created_by_id: @admin.id, description: 'Disposable pagination test')
    headers = {'Api-Key' => key.key, 'Api-Username' => @alice.username}
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'community.test'
    session.get '/rsc/forecast/state.json', headers: headers
    assert_equal 200, session.response.status, session.response.body
    first = JSON.parse(session.response.body)
    assert_equal 100, first['holdings'].size
    assert_equal 101, first.dig('holdings_pagination', 'total')
    assert_equal 30, first['trades'].size
    assert_equal 31, first.dig('trades_pagination', 'total')
    session.get '/rsc/forecast/portfolio.json', params: {kind: 'holdings', page: 2}, headers: headers
    assert_equal 200, session.response.status, session.response.body
    last = JSON.parse(session.response.body)
    assert_equal 1, last['items'].size
    assert_equal 101, (first['holdings'] + last['items']).map { |p| p['id'] }.uniq.size
    session.get "/rsc/forecast/markets/#{@market.id}.json", headers: headers
    assert_equal ['3'], JSON.parse(session.response.body)['holdings'].map { |p| p['shares'] }
    session.get '/rsc/forecast/portfolio.json', params: {kind: 'trades', page: 999, user_id: @bob.id}, headers: headers
    last = JSON.parse(session.response.body)
    assert_equal 2, last['page']
    assert_equal 1, last['items'].size
    assert_equal '2', last['items'].first['shares']
    session.get '/rsc/forecast/portfolio.json', params: {kind: 'other'}, headers: headers
    assert_equal 422, session.response.status
  ensure
    key&.destroy!
  end
end
