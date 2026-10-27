# frozen_string_literal: true
require '/rsc/test/forex_activity_test'
class ErrorMessagesTest < ForexActivityTest
  ForexActivityTest.instance_methods.grep(/^test_/).each { |name| undef_method name }
  def test_api_and_order_failures_have_chinese_messages_even_in_english_locale
    I18n.with_locale(:en) do
      %w[quote_stale order_pending market_closed insufficient_balance position_conflict invalid_amount price_moved provider_http_504 never_seen_before].each do |code|
        assert_match(/[\p{Han}]/, R::Error.user_message(code),code)
        refute_equal code,R::Error.user_message(code)
      end
    end
  end
  def test_http_response_keeps_code_and_chinese_text
    item=instrument
    @alice.update!(locale:'en')
    session=ActionDispatch::Integration::Session.new(Rails.application)
    session.host!('rsc.test');session.https!
    key=ApiKey.create!(user_id:@alice.id,created_by_id:@admin.id,description:'isolated Chinese error test')
    session.post '/rsc/orders.json',headers:{'Api-Key'=>key.key,'Api-Username'=>@alice.username,'Accept-Language'=>'en'},params:{
      instrument_id:item.id,side:'long',quantity:'0',leverage:1,request_id:'chinese-invalid-quantity'
    }
    assert_equal 422,session.response.status
    body=JSON.parse(session.response.body)
    assert_equal 'invalid_amount',body['error_code']
    assert_match(/[\p{Han}]/,body['errors'].first)
  ensure
    key&.destroy!
  end

end
