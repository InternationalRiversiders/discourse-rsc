# frozen_string_literal: true
abort 'Disposable database only' unless ENV['RIVER_DISPOSABLE'] == '1' && GlobalSetting.db_name == 'river_community_test'
require 'minitest/autorun'

class ForecastTest < Minitest::Test
  R = DiscourseRsc
  def setup
    RateLimiter.disable
    tables = ActiveRecord::Base.connection.tables.grep(/\Adiscourse_rsc_/)
    ActiveRecord::Base.connection.execute("TRUNCATE #{tables.join(',')} RESTART IDENTITY CASCADE")
    SiteSetting.rsc_enabled = true
    SiteSetting.rsc_native_trial_enabled = true
    SiteSetting.rsc_forecast_enabled = true
    SiteSetting.rsc_read_only = false
    SiteSetting.rsc_notifications_enabled = false
    SiteSetting.force_https = false
    @group = Group.find_or_create_by!(name: 'forecast_members')
    SiteSetting.rsc_allowed_groups = @group.id.to_s
    @admin = user('forecast_admin', true)
    @alice = user('forecast_alice')
    @bob = user('forecast_bob')
    @group.add(@alice); @group.add(@bob)
    @alice.reload; @bob.reload
    R::Wallet.issue(actor: @admin, recipient: @alice, amount: '100', reason: 'isolated forecast test', request_id: SecureRandom.uuid)
    @raw = { 'id'=>'100', 'conditionId'=>'0x'+'1'*64, 'question'=>'Will the demo resolve Yes?', 'slug'=>'forecast-demo',
      'description'=>'Synthetic test: final resolution determines each share payout.', 'outcomes'=>'["Yes","No"]', 'clobTokenIds'=>'["123","456"]',
      'outcomePrices'=>'["0.5","0.5"]', 'endDate'=>2.days.from_now.iso8601, 'active'=>true, 'closed'=>false,
      'acceptingOrders'=>true, 'enableOrderBook'=>true, 'volume24hr'=>'20000', 'liquidity'=>'10000' }
    @market = R::ForecastProvider.ingest(@raw)
    @resolution = nil
    @bids = [{ 'price'=>'0.4', 'size'=>'1000' }]
    @asks = [{ 'price'=>'0.5', 'size'=>'1000' }]
  end
  def user(name, admin=false)
    User.find_by(username: name) || User.create!(username: name, email: "#{name}@example.com", password: SecureRandom.hex(24), active: true, approved: true, admin: admin)
  end
  def provider
    raw, resolution, bids, asks, market = @raw, @resolution, @bids, @asks, @market
    fetch = lambda do |host,path,query={}|
      case host
      when R::ForecastProvider::GAMMA then path == '/markets' ? [raw] : raw
      when R::ForecastProvider::DATA then { 'data'=>[resolution].compact }
      when R::ForecastProvider::CLOB
        if path == '/book'
          { 'market'=>market.condition_id, 'asset_id'=>query[:token_id], 'timestamp'=>(Time.current.to_f*1000).to_i.to_s, 'asks'=>asks, 'bids'=>bids }
        else
          { 'history'=>[{ 't'=>1,'p'=>'0.4' },{ 't'=>2,'p'=>'0.5' }] }
        end
      else raise 'Unexpected provider'
      end
    end
    original = R::ForecastProvider.method(:get)
    R::ForecastProvider.define_singleton_method(:get, fetch)
    yield
  ensure
    R::ForecastProvider.define_singleton_method(:get, original) if original
  end
  def quote(side='buy', amount='10', outcome=0)
    provider { R::ForecastExchange.quote(actor: @alice, market_id: @market.id, outcome: outcome, side: side, amount: amount) }
  end
  def execute(q, request_id=SecureRandom.uuid, actor=@alice)
    R::ForecastExchange.execute(actor: actor, token: q[:token], request_id: request_id)
  end
  def final(values=[1_000_000,0])
    { 'condition_id'=>@market.condition_id, 'status'=>'resolved','extended_review'=>false,'payouts'=>values,
      'resolved_at'=>5.minutes.ago.iso8601,'resolved_block'=>123 }
  end
  def confirm_resolution(values=[1_000_000,0])
    row=final(values)
    R::ForecastSettlement.observe(@market,row)
    assert_equal 'awaiting',@market.reload.state
    assert_equal 0,R::ForecastSettlement.settle(@market)
    @market.update!(resolution_seen_at:3.minutes.ago)
    R::ForecastSettlement.observe(@market,row)
    assert_equal 'resolved',@market.reload.state
  end
  def test_buy_replay_and_wallet_total_assets
    q=quote
    assert_equal '20',q[:shares]
    assert_equal '10',q[:cash]
    first=execute(q,'forecast-replay')
    assert execute(q,'forecast-replay')['replayed']
    assert_equal '90',R::Account.wallet(@alice.id).balance
    assert_equal 1,R::ForecastTrade.count
    assert_equal '100',R::Reports.portfolio(@alice.id)[:equity]
    assert_equal '0.0',R::Reports.portfolio(@alice.id)[:total_pnl]
    assert_equal 'cost',R::Reports.portfolio(@alice.id)[:valuation_basis]
    assert_equal first['trade_id'],R::ForecastTrade.first.id
    assert_equal 0,R::Account.sum(:balance_units)
  end
  def test_depth_weighted_quote_and_insufficient_depth
    @asks=[{'price'=>'0.6','size'=>'100'},{'price'=>'0.5','size'=>'10'}]
    q=quote('buy','11')
    assert_equal '20',q[:shares]
    assert_equal '11',q[:cash]
    @asks=[{'price'=>'0.5','size'=>'1'}]
    assert_equal 'forecast_liquidity',assert_raises(R::Error) { quote }.code
    assert_equal '100',R::Account.wallet(@alice.id).balance
  end
  def test_sell_partial_then_full_and_escrow_conservation
    execute(quote)
    execute(quote('sell','5'))
    position=R::ForecastPosition.first
    assert_equal R::Amount.parse('15'),position.shares_units
    assert_equal R::Amount.parse('7.5'),position.cost_units
    assert_equal R::Amount.parse('-0.5'.delete_prefix('-')) * -1,position.realized_units
    execute(quote('sell','15'))
    assert_equal '98',R::Account.wallet(@alice.id).balance
    assert_equal 0,position.reload.shares_units
    assert_equal 0,R::Account.where(kind:'escrow').sum(:balance_units)
    assert_equal '-2.0',R::Reports.portfolio(@alice.id)[:total_pnl]
  end
  def test_invalid_or_expired_quotes_never_charge
    q=quote
    R::ForecastQuote.find_by!(token:q[:token]).update!(expires_at:1.second.ago)
    assert_equal 'forecast_quote_expired',assert_raises(R::Error) { execute(q) }.code
    q=quote
    assert_raises(ActiveRecord::RecordNotFound) { execute(q,SecureRandom.uuid,@bob) }
    SiteSetting.rsc_read_only=true
    assert_equal 'read_only',assert_raises(R::Error) { execute(q) }.code
    assert_equal '100',R::Account.wallet(@alice.id).balance
  end
  def test_insufficient_balance_rolls_back_position_and_quote
    q=quote
    R::Wallet.transfer(actor:@alice,recipient:@bob,amount:'100',request_id:SecureRandom.uuid)
    assert_equal 'insufficient_balance',assert_raises(R::Error) { execute(q) }.code
    assert_equal 0,R::ForecastPosition.count
    assert_nil R::ForecastQuote.find_by!(token:q[:token]).used_at
  end
  def test_terms_changes_pause_market_and_outstanding_quote
    q=quote
    @raw['outcomes']='["No","Yes"]'
    provider { R::ForecastProvider.refresh(@market) }
    assert_equal 'review',@market.reload.state
    assert_equal ['Yes','No'],@market.outcomes
    assert_equal 'forecast_closed',assert_raises(R::Error) { execute(q) }.code
  end
  def test_proposed_disputed_invalid_result_dont_pay
    execute(quote)
    %w[proposed disputed unknown resolved].each do |state|
      R::ForecastSettlement.observe(@market,final.merge('status'=>state,'payouts'=>[1,1,1]))
      assert_equal 0,R::ForecastSettlement.settle(@market.reload)
    end
    R::ForecastSettlement.observe(@market,final.merge('extended_review'=>true))
    assert_equal 0,R::ForecastSettlement.settle(@market.reload)
    assert_equal '90',R::Account.wallet(@alice.id).balance
  end
  def test_closed_flag_and_price_are_not_result
    execute(quote)
    @raw.merge!('closed'=>true,'outcomePrices'=>'["1","0"]')
    provider { R::ForecastProvider.refresh(@market) }
    assert_equal 'awaiting',@market.reload.state
    assert_equal 0,R::ForecastSettlement.settle(@market)
  end
  def test_win_settlement_once_notification_and_frozen_wallet
    execute(quote)
    R::Account.wallet(@alice.id).update!(status:'frozen')
    confirm_resolution
    assert_equal 1,R::ForecastSettlement.settle(@market)
    assert_equal 0,R::ForecastSettlement.settle(@market.reload)
    assert_equal '110',R::Account.wallet(@alice.id).balance
    assert_equal 0,R::Account.where(kind:'escrow').sum(:balance_units)
    event=R::Event.find_by!(kind:'forecast_settled')
    R::NotificationDelivery.deliver(event)
    R::NotificationDelivery.deliver(event.reload)
    assert_equal "/rsc/forecast?market_id=#{@market.id}",Notification.find(event.reload.notification_id).data_hash['rsc_path']
    assert_equal 1,R::Event.where(kind:'forecast_settled').count
    assert_equal '10.0',R::Reports.portfolio(@alice.id)[:total_pnl]
  end
  def test_loser_and_half_payout
    execute(quote('buy','10',0))
    execute(quote('buy','10',1))
    confirm_resolution([0,1_000_000])
    assert_equal 2,R::ForecastSettlement.settle(@market)
    assert_equal '100',R::Account.wallet(@alice.id).balance
    assert_equal ['0','20'],R::Event.where(kind:'forecast_settled').order(:id).map { |e| e.payload['amount'] }
    assert_equal 0,R::Account.where(kind:'escrow').sum(:balance_units)
  end
  def test_half_is_share_redemption_not_refund
    @asks=[{'price'=>'0.25','size'=>'1000'}]
    execute(quote)
    confirm_resolution([500_000,500_000])
    assert_equal 1,R::ForecastSettlement.settle(@market)
    assert_equal '110',R::Account.wallet(@alice.id).balance
  end
  def test_resolution_mismatch_or_changes_restart_confirmation
    execute(quote)
    R::ForecastSettlement.observe(@market,final.merge('condition_id'=>'0x'+'2'*64))
    assert_nil @market.reload.resolution_seen_at
    R::ForecastSettlement.observe(@market,final)
    @market.update!(resolution_seen_at:3.minutes.ago)
    R::ForecastSettlement.observe(@market,final([0,1_000_000]))
    assert_equal 'awaiting',@market.reload.state
    assert_nil @market.confirmed_at
  end
  def test_limits_stale_quotes_and_disabled_feature
    assert_equal 'forecast_limit',assert_raises(R::Error) { quote('buy','501') }.code
    assert_equal 'forecast_limit',assert_raises(R::Error) { quote('buy','0.1') }.code
    assert_equal 'forecast_shares',assert_raises(R::Error) { quote('sell','1') }.code
    q=quote
    @market.update!(synced_at:2.minutes.ago)
    assert_equal 'forecast_closed',assert_raises(R::Error) { execute(q) }.code
    SiteSetting.rsc_forecast_enabled=false
    assert_equal 'forecast_disabled',assert_raises(R::Error) { quote }.code
  end
  def test_http_access_and_trade_identity
    session=ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'community.test'
    session.get '/rsc/forecast/state.json'
    assert_includes [401,403],session.response.status
    key=ApiKey.create!(user_id:@alice.id,created_by_id:@admin.id,description:'Disposable forecast test')
    headers={'Api-Key'=>key.key,'Api-Username'=>@alice.username}
    session.get '/rsc/forecast/state.json',headers:headers
    assert_equal 200,session.response.status,session.response.body
    assert_equal @market.question,JSON.parse(session.response.body)['markets'].first['question']
    q=quote
    session.post '/rsc/forecast/trades.json',params:{token:q[:token],request_id:'forecast-http-test',user_id:@bob.id},headers:headers,as: :json
    assert_equal 200,session.response.status,session.response.body
    assert_equal @alice.id,R::ForecastTrade.last.user_id
    SiteSetting.rsc_forecast_enabled=false
    session.get '/rsc/forecast/state.json',headers:headers
    assert_equal 404,session.response.status
  end
  def test_nonpopular_holdings_are_still_polled_and_settled
    execute(quote)
    @market.update!(featured:false)
    @raw['closed']=true
    @resolution=final
    Discourse.redis.setex('rsc:forecast:discovered',600,'1')
    provider { R::ForecastSettlement.tick }
    assert_equal 'awaiting',@market.reload.state
    @market.update!(resolution_seen_at:3.minutes.ago)
    provider { R::ForecastSettlement.tick }
    assert_equal 'resolved',@market.reload.state
    assert @market.settled_at
    assert_equal '110',R::Account.wallet(@alice.id).balance
  end

  def test_same_quote_concurrent_commands_cannot_double_spend
    q=quote
    results=2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          begin
            execute(q)
            :filled
          rescue R::Error => error
            error.code
          end
        end
      end
    end.map(&:value)
    assert_equal 1,results.count(:filled)
    assert_equal 1,results.count('forecast_quote_expired')
    assert_equal '90',R::Account.wallet(@alice.id).balance
    assert_equal 1,R::ForecastTrade.count
  end

  def test_changed_final_result_is_not_paid_twice
    execute(quote)
    confirm_resolution
    R::ForecastSettlement.settle(@market)
    R::ForecastSettlement.observe(@market,final([0,1000000]))
    assert_equal 0,R::ForecastSettlement.settle(@market)
    assert_equal '110',R::Account.wallet(@alice.id).balance
    assert R::Audit.exists?(action:'forecast_resolution_changed')
  end

  def test_parser_and_provider_book_reject_bad_identifiers_and_stale_time
    assert_nil R::ForecastProvider.parse(@raw.merge('clobTokenIds'=>'["123","123"]'))
    assert_nil R::ForecastProvider.parse(@raw.merge('conditionId'=>'http://localhost'))
    assert_nil R::ForecastProvider.parse(@raw.merge('outcomePrices'=>'["NaN","0.5"]'))
    original=R::ForecastProvider.method(:get)
    stale={ 'market'=>@market.condition_id,'asset_id'=>'123','timestamp'=>(2.minutes.ago.to_f*1000).to_i.to_s }
    R::ForecastProvider.define_singleton_method(:get) { |*_| stale }
    assert_equal 'forecast_stale',assert_raises(R::Error) { R::ForecastProvider.book(@market,0) }.code
  ensure
    R::ForecastProvider.define_singleton_method(:get,original) if original
  end

end
