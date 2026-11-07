# frozen_string_literal: true
module DiscourseRsc
  class ArcadeRun < ActiveRecord::Base
    self.table_name = 'discourse_rsc_arcade_runs'
    after_commit :refresh_rankings, if: -> { status == 'finished' || status_before_last_save == 'finished' }

    private

    def refresh_rankings
      Rails.cache.delete(Arcade.rank_cache_key(nil,game))
      Rails.cache.delete(Arcade.rank_cache_key(period_id,game))
    end
  end
  class ArcadePeriod < ActiveRecord::Base
    self.table_name = 'discourse_rsc_arcade_periods'
  end
end
