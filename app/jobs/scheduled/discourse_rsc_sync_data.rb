# frozen_string_literal: true
module Jobs
  class DiscourseRscSyncData < ::Jobs::Scheduled
    every 1.minute
    def execute(args)
      DiscourseRscProviderPoll.enqueue_once('full')
      DiscourseRscProviderPoll.enqueue_once('forex_morning')
    end
  end
end
