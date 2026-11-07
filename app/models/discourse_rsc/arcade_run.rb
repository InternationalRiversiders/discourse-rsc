# frozen_string_literal: true
module DiscourseRsc
  class ArcadeRun < ActiveRecord::Base
    self.table_name = 'discourse_rsc_arcade_runs'
  end
  class ArcadePeriod < ActiveRecord::Base
    self.table_name = 'discourse_rsc_arcade_periods'
  end
end
