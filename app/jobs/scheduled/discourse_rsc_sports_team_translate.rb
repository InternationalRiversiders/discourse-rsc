# frozen_string_literal: true
module Jobs
  class DiscourseRscSportsTeamTranslate < ::Jobs::Scheduled
    every 1.minute
    def execute(_args)
      DiscourseRsc::SportsTeamTranslation.tick
    end
  end
end
