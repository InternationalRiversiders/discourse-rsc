# frozen_string_literal: true
require "json"
require "uri"

module DiscourseRsc
  module SportsPresentation
    NAMES = JSON.parse(File.read(File.expand_path("../../../config/sports_names.zh_CN.json", __dir__))).freeze
    TEAMS = NAMES.fetch("teams").transform_keys(&:downcase).freeze
    FLAGS = NAMES.fetch("flags").transform_keys(&:downcase).freeze
    STAGES = {
      "English Premier League" => "英超", "LALIGA" => "西甲", "Serie A" => "意甲",
      "Bundesliga" => "德甲", "Ligue 1" => "法甲", "Chinese Super League" => "中超",
      "UEFA Champions League" => "欧冠", "UEFA Europa League" => "欧联",
      "FIFA World Cup" => "世界杯", "Regular Season" => "常规赛", "Preseason" => "季前赛",
      "Playoffs" => "季后赛", "Group Stage" => "小组赛", "League Phase" => "联赛阶段",
      "Round of 32" => "32强赛", "Round of 16" => "16强赛", "Quarterfinals" => "四分之一决赛",
      "Quarter-finals" => "四分之一决赛", "Semifinals" => "半决赛", "Semi-finals" => "半决赛",
      "Third Place" => "季军赛", "Final" => "决赛", "1st Leg" => "首回合", "2nd Leg" => "次回合",
    }.freeze

    def self.chinese?
      I18n.locale.to_s.start_with?("zh")
    end

    def self.team(name)
      chinese? ? TEAMS.fetch(name.to_s.downcase, name) : name
    end

    def self.stage(value)
      return value unless chinese? && value.present?
      value.gsub(Regexp.union(STAGES.keys.sort_by { |key| -key.length }), STAGES)
        .gsub(/\bGroup ([A-L])\b/, '\1组')
    end

    def self.status_detail(value)
      return value unless chinese?
      { "FT" => "全场结束", "Final" => "已结束", "HT" => "中场休息", "Halftime" => "中场休息",
        "AET" => "加时结束", "FT-Pens" => "点球大战结束", "Postponed" => "已延期",
        "Canceled" => "已取消", "Cancelled" => "已取消", "Delayed" => "延迟开赛" }.fetch(value, value)
    end

    # Remote logos are display-only. Do not accept arbitrary URLs from imported
    # data, and never fetch a team-provided URL from the forum server.
    def self.safe_logo(value)
      return unless value.is_a?(String) && value.length < 2048
      uri = URI.parse(value)
      return unless uri.scheme == "https" && uri.userinfo.nil? && uri.port == 443
      return unless uri.host&.match?(/\Aa\d?\.espncdn\.com\z/) || uri.host == "flagcdn.com"
      value
    rescue URI::InvalidURIError
      nil
    end

    def self.logo(data, side, name)
      safe_logo(data["#{side}_logo"]) || begin
        code = FLAGS[name.to_s.downcase]
        "https://flagcdn.com/w80/#{code}.png" if code
      end
    end

    def self.provider_team(team)
      logo = safe_logo(team["logo"]) || Array(team["logos"]).filter_map { |item| safe_logo(item["href"]) }.first
      { "logo" => logo, "abbr" => team["abbreviation"].presence }.compact
    end

    # Recover presentation metadata from already imported historical records.
    # Never run the event ingester here: that could change odds or settlement.
    def self.restore_legacy_badges!(apply: false)
      by_event = {}; by_team = {}
      LegacyRecord.where(source_table: "world_cup_matches").order(:id).find_each do |row|
        data = row.data
        by_event[data["external_id"].to_s] = data
        %w[home away].each do |side|
          logo = safe_logo(data["#{side}_logo"])
          by_team[[data.fetch("sport_key", "soccer"), data["#{side}_team"]]] = logo if logo
        end
      end
      count = 0
      SportMatch.find_each do |match|
        match.with_lock do
          data = match.provider_data.dup
          legacy = by_event[match.external_id] || {}
          %w[home away].each do |side|
            next if safe_logo(data["#{side}_logo"])
            name = match.public_send(side)
            logo = legacy["#{side}_team"] == name ? safe_logo(legacy["#{side}_logo"]) : nil
            logo ||= by_team[[match.sport, name]]
            data["#{side}_logo"] = logo if logo
          end
          next if data == match.provider_data
          count += 1
          match.update!(provider_data: data) if apply
        end
      end
      { matches: count, applied: apply }
    end
  end
end
