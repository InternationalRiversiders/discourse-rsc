# frozen_string_literal: true
module Jobs
  # Refresh the browsable catalog independently of the daily settlement batch.
  class DiscourseRscForecastDiscover < ::Jobs::Scheduled
    every 10.minutes
    def execute(_args)
      return unless DiscourseRsc::ForecastSettlement.enabled?
      DistributedMutex.synchronize('rsc-forecast-discovery', validity: 90) do
        DiscourseRsc::ForecastProvider.discover
      end
    end
  end
end
