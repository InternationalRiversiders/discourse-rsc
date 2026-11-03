# frozen_string_literal: true

module DiscourseRsc
  class Error < StandardError
    attr_reader :code, :status, :details

    # API clients may send an English locale; RSC's member-facing failures
    # remain Chinese, with a stable machine-readable code alongside the text.
    def self.user_message(code, details = {})
      if %w[invalid_protection take_profit_not_profitable stop_loss_beyond_liquidation].include?(code) && details[:field] && details[:boundary]
        field = details[:field] == 'take_profit' ? '止盈价' : '止损价'
        relation = details[:relation] == 'above' ? '大于' : '小于'
        reference = { 'current_price' => '当前有效报价', 'take_profit' => '止盈价', 'stop_loss' => '止损价', 'break_even' => '保本价', 'liquidation' => '强平价' }.fetch(details[:reference], '参考价')
        return "#{field}须#{relation}#{reference} #{details[:boundary]} RSC／单位。请输入触发价格，而不是预计盈亏金额。"
      end
      key = "discourse_rsc.errors.#{code}"
      fallback = code.to_s.start_with?("provider_") ? "provider_unavailable" : "request_failed"
      I18n.t(key, locale: :zh_CN, default: I18n.t("discourse_rsc.errors.#{fallback}", locale: :zh_CN))
    end

    def initialize(code, status: 422, details: {})
      @code = code
      @status = status
      @details = details
      super(code)
    end
  end
end
