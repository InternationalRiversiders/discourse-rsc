# frozen_string_literal: true
require '/rsc/test/business_test'
class ArcadeEmbedTest < NativeBusinessTest
  NativeBusinessTest.instance_methods(false).grep(/^test_/).each { |n| undef_method n }
  def setup
    super
    SiteSetting.rsc_arcade_enabled = true
    SiteSetting.login_required = true
    SiteSetting.force_https = false
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host!('rsc.test')
  end
  def teardown
    SiteSetting.login_required = false
    super
  end
  def test_public_shell_has_no_identity_and_does_not_grant_api_access
    @session.get('/rsc/arcade/embed?game=2048&mode=native')
    assert_equal 200, @session.response.status
    assert_equal 'no-store', @session.response.headers['Cache-Control']
    assert_includes @session.response.headers['Content-Security-Policy'], "connect-src 'none'"
    assert_equal 'SAMEORIGIN', @session.response.headers['X-Frame-Options']
    assert_includes @session.response.body, 'id="arcade"'
    refute_includes @session.response.body, @alice.username
    @session.get('/rsc/arcade/catalog.json', headers: {'HTTP_X_REQUESTED_WITH'=>'XMLHttpRequest'})
    assert_includes [302,403], @session.response.status
  end
  def test_disabled_arcade_has_no_embed_entry
    SiteSetting.rsc_arcade_enabled = false
    @session.get('/rsc/arcade/embed')
    assert_equal 404, @session.response.status
  end
end
