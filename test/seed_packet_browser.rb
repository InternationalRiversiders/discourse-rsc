# frozen_string_literal: true
abort "Disposable forum only" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_discourse_smoke"
R = DiscourseRsc
credentials = JSON.parse(File.read("/tmp/river-browser-credentials.json"))
alice = User.find_by!(username: credentials.fetch("alice").fetch("username"))
Group.find_by!(name: "rsc_test_members").add(alice)
sender = User.find_by!(username: "rsc_bob")
Group.find_by!(name: "river_test_members").add(sender)
result = R::RedPackets.create(actor: sender, mode: "fixed", count: 3, amount: "2", message: "愿你今天也有好心情", days: 7, request_id: SecureRandom.uuid)
packet = R::Packet.find_by!(token: result["token"])
packet.update!(expires_at: 90.days.from_now.utc.change(hour: 4, min: 5, sec: 6))
category = Category.find_by!(name: "RSC public test")
post = PostCreator.create!(sender, category: category.id, title: "红包原生分享卡片验证", raw: "#{R::PacketSharing.url(packet)}\n\nhttps://coin.river-side.cc/red-packet/#{packet.token}")
post.rebake!(invalidate_oneboxes: true)
Jobs::ProcessPost.new.execute(post_id: post.id)
raise "Missing cooked oneboxes" unless Post.find(post.id).cooked.scan('rsc-packet-onebox').length == 2
credentials["packet_path"] = "/rsc/packets/#{packet.token}"
credentials["packet_post_path"] = "/t/#{post.topic_id}"
File.write("/tmp/campus-packet-browser.json", credentials.to_json, perm: 0o600)
