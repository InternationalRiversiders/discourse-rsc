# frozen_string_literal: true
module Jobs
  class DiscourseRscForecastTranslate < ::Jobs::Scheduled
    every 1.minute
    def execute(_args)
      DiscourseRsc::ForecastTranslation.tick
    end
  end
end
