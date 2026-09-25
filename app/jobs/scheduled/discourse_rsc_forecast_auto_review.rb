# frozen_string_literal: true
module Jobs
  class DiscourseRscForecastAutoReview < ::Jobs::Scheduled
    every 1.minute
    def execute(_args)
      DiscourseRsc::ForecastAutoReview.tick
    end
  end
end
