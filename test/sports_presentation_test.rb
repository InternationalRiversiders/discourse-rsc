# frozen_string_literal: true
require "/rsc/test/migration_features_test"

class SportsPresentationTest < MigrationFeaturesTest
  def test_sports_presentation_sync_and_missing_logo_preserves_prior_image
    event = espn_event(name: "STATUS_FULL_TIME")
    teams = event["competitions"][0]["competitors"]
    teams[0]["team"].merge!("displayName" => "Arsenal", "logo" => "https://a.espncdn.com/i/teamlogos/soccer/500/359.png")
    teams[1]["team"].merge!("displayName" => "Liverpool", "logos" => [{ "href" => "https://a.espncdn.com/i/teamlogos/soccer/500/364.png" }])
    R::SportsData.ingest(event, sport: "soccer", league: "eng.1")
    match = R::SportMatch.find_by!(external_id: "espn:soccer:eng.1:fixture-1")
    assert_includes match.provider_data["home_logo"], "359.png"
    assert_includes match.provider_data["away_logo"], "364.png"
    teams[0]["team"].delete("logo")
    teams[1]["team"]["logos"] = [{ "href" => "javascript:alert(1)" }]
    R::SportsData.ingest(event, sport: "soccer", league: "eng.1")
    assert_includes match.reload.provider_data["home_logo"], "359.png"
    assert_includes match.provider_data["away_logo"], "364.png"
    I18n.with_locale(:zh_CN) do
      row = R::Views.matches(@alice.id).find { |item| item[:id] == match.id }
      assert_equal "Arsenal", row[:home]
      assert_equal "阿森纳", row[:home_name]
      assert_equal "利物浦", row[:away_name]
      assert_equal match.provider_data["home_logo"], row[:home_logo]
    end
  end

  def test_sports_presentation_localization_and_untrusted_images
    presentation = R::SportsPresentation
    I18n.with_locale(:zh_CN) do
      assert_equal "曼联", presentation.team("Manchester United")
      assert_equal "新球队", presentation.team("新球队")
      assert_equal "Unknown FC", presentation.team("Unknown FC")
      assert_equal "世界杯, A组", presentation.stage("FIFA World Cup, Group A")
      assert_equal "四分之一决赛", presentation.stage("Quarter-finals")
      assert_equal "全场结束", presentation.status_detail("FT")
    end
    I18n.with_locale(:en) { assert_equal "Manchester United", presentation.team("Manchester United") }
    assert_equal "https://flagcdn.com/w80/gb-eng.png", presentation.logo({}, "home", "England")
    assert_nil presentation.logo({}, "home", "Unknown FC")
    ["http://a.espncdn.com/image.png", "https://a.espncdn.com.evil.test/image.png", "https://user:pass@a.espncdn.com/image.png", "javascript:alert(1)", "data:image/svg+xml,x"].each do |url|
      assert_nil presentation.safe_logo(url)
    end
  end

  def test_sports_presentation_backfill_is_idempotent_and_does_not_touch_business_fields
    match = R::SportMatch.create!(external_id: "badge-history", sport: "soccer", league: "eng.1", home: "Arsenal", away: "Unknown FC", starts_at: 1.day.from_now, status: "scheduled", odds: {home:"1.5"}, odds_at: Time.current, provider_data: {manual_result:true,stage:"Final"})
    R::LegacyRecord.create!(source_table: "world_cup_matches", source_id: "badge-test", created_at: Time.current, data: {external_id:"another-event",sport_key:"soccer",home_team:"Arsenal",home_logo:"https://a.espncdn.com/i/teamlogos/soccer/500/359.png",away_team:"Someone Else"})
    before = match.attributes.except("provider_data", "updated_at")
    ledger_before = [R::Journal.count, R::Entry.count, R::Prediction.count]
    assert_equal({matches:1,applied:false}, R::SportsPresentation.restore_legacy_badges!)
    assert_nil match.reload.provider_data["home_logo"]
    assert_equal({matches:1,applied:true}, R::SportsPresentation.restore_legacy_badges!(apply:true))
    assert_equal before, match.reload.attributes.except("provider_data", "updated_at")
    assert_equal true, match.provider_data["manual_result"]
    assert_equal "Final", match.provider_data["stage"]
    assert_nil match.provider_data["away_logo"]
    assert_equal 0, R::SportsPresentation.restore_legacy_badges!(apply:true)[:matches]
    assert_equal ledger_before, [R::Journal.count, R::Entry.count, R::Prediction.count]
  end
end
