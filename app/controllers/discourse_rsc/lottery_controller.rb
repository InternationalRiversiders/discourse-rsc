# frozen_string_literal: true
module DiscourseRsc
  class LotteryController < WalletController
    def index
      Lottery.ensure_access!(current_user)
      render 'default/empty'
    end
    def state
      render_json_dump Lottery.state(current_user)
    end
    def auto_plan
      RateLimiter.new(current_user, 'rsc-lottery-plan', 20, 1.minute).performed!
      rows = params[:selections]
      raise Error.new('lottery_plan_invalid') unless rows.is_a?(Array)
      rows = rows.map { |r| r.respond_to?(:permit) ? r.permit(:number,:quantity,:enabled).to_h : r }
      render_json_dump LotteryAutobet.save(actor:current_user,selections:rows,version:params[:version])
    end
    def buy
      RateLimiter.new(current_user, 'rsc-lottery-buy', 30, 1.minute).performed!
      quantity = params.require(:quantity).to_s
      raise Error.new('lottery_quantity') unless /\A[0-9]{1,2}\z/.match?(quantity)
      render_json_dump Lottery.buy(actor: current_user, draw_id: positive_id(:draw_id),
        number: params.require(:number), quantity: quantity.to_i, request_id: params.require(:request_id))
    end
  end
end
