# frozen_string_literal: true
abort "Disposable forum only" unless ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_discourse_smoke"
match = DiscourseRsc::SportMatch.find_by!(external_id: "trial-soccer")
match.update!(league: "eng.1", home: "Arsenal", away: "Liverpool", provider_data: {
  home_logo: "https://a.espncdn.com/i/teamlogos/soccer/500/359.png",
  away_logo: "https://a.espncdn.com/i/teamlogos/soccer/500/364.png", stage: "Group A",
})
DiscourseRsc::SportMatch.find_by!(external_id: "trial-basketball").update!(home: "Boston Celtics", away: "Unknown FC")
