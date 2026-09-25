# frozen_string_literal: true
module Jobs
  class DiscourseRscForecastTick < ::Jobs::Scheduled
    every 1.minute
    def execute(_args)
      DiscourseRsc::ForecastSettlement.tick
    end
  end
end
