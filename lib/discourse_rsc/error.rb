# frozen_string_literal: true

module DiscourseRsc
  class Error < StandardError
    attr_reader :code, :status

    # API clients may send an English locale; RSC's member-facing failures
    # remain Chinese, with a stable machine-readable code alongside the text.
    def self.user_message(code)
      key = "discourse_rsc.errors.#{code}"
      fallback = code.to_s.start_with?("provider_") ? "provider_unavailable" : "request_failed"
      I18n.t(key, locale: :zh_CN, default: I18n.t("discourse_rsc.errors.#{fallback}", locale: :zh_CN))
    end

    def initialize(code, status: 422)
      @code = code
      @status = status
      super(code)
    end
  end
end
