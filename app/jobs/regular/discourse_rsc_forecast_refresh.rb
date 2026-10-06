# frozen_string_literal: true
module Jobs
  class DiscourseRscForecastRefresh < ::Jobs::Base
    def execute(args)
      DiscourseRsc::ForecastSettlement.refresh_market(args[:market_id], confirm: args[:confirm] == true)
    end
  end
end
