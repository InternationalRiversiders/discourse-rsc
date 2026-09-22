# frozen_string_literal: true
require "/rsc/test/business_test"

class PacketSharingTest < NativeBusinessTest
  def test_packet_sharing_native_old_and_inline_oneboxes_only_show_public_envelope
    fund
    result = R::RedPackets.create(actor:@alice, mode:"fixed", count:3, amount:"2", message:'红包 <script>alert("x")</script>', request_id:SecureRandom.uuid)
    packet = R::Packet.find_by!(token:result["token"])
    R::RedPackets.claim(actor:@bob,token:packet.token,request_id:SecureRandom.uuid)
    before = [R::Journal.count,R::Entry.count,R::PacketClaim.count]
    url = R::PacketSharing.url(packet)
    [Oneboxer.preview(url), Oneboxer.preview("https://coin.river-side.cc/red-packet/#{packet.token}")].each do |html|
      assert_includes html, "rsc-packet-onebox"
      assert_includes html, "6 RSC"
      assert_includes html, "&lt;script&gt;"
      refute_includes html, "<script>"
      refute_includes html, @bob.username
      refute_includes html, "allocations"
      refute_includes html, "remaining"
      assert_includes html, url
    end
    route=Discourse.route_for(url)
    inline=InlineOneboxer.local_handlers.fetch(route[:controller]).call(url,route)
    assert_equal R::PacketSharing.title(packet),inline[:title]
    assert_equal R::PacketSharing.title(packet), InlineOneboxer.lookup("https://coin.river-side.cc/red-packet/#{packet.token}")[:title]
    refute R::PacketSharing::LEGACY_URL.match?("https://coin.river-side.cc.example.com/red-packet/#{packet.token}")
    refute R::PacketSharing::LEGACY_URL.match?("https://coin.river-side.cc@evil.example/red-packet/#{packet.token}")
    assert_equal before,[R::Journal.count,R::Entry.count,R::PacketClaim.count]
  end

  def test_packet_sharing_metadata_is_available_without_login_and_unknown_tokens_404
    fund
    result=R::RedPackets.create(actor:@alice,mode:"fixed",count:2,amount:"1",message:"测试分享",request_id:SecureRandom.uuid)
    packet=R::Packet.find_by!(token:result["token"])
    SiteSetting.login_required=false
    SiteSetting.force_https=false
    session=ActionDispatch::Integration::Session.new(Rails.application)
    session.host! Discourse.current_hostname
    session.get "/rsc/packets/#{packet.token}"
    assert_equal 200,session.response.status
    doc=Nokogiri::HTML(session.response.body)
    assert_equal R::PacketSharing.title(packet),doc.at_css('meta[property="og:title"]')['content']
    assert_includes doc.at_css('meta[property="og:description"]')['content'],"2 RSC"
    session.get "/rsc/packets/unknown-packet-token"
    assert_equal 404,session.response.status
    SiteSetting.rsc_native_trial_enabled=false
    assert_nil R::PacketSharing.lookup(packet.token)
    assert_nil R::PacketSharing.lookup("../bad")
  end
end
