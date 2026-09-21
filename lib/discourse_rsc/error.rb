# frozen_string_literal: true

module DiscourseRsc
  class Error < StandardError
    attr_reader :code, :status

    def initialize(code, status: 422)
      @code = code
      @status = status
      super(code)
    end
  end
end
