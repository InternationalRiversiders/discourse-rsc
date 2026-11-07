# frozen_string_literal: true
module DiscourseRsc
  class GamesController < WalletController
    def index
      Games.ensure_access!(current_user)
      render 'default/empty'
    end
    def state
      render_json_dump Games.state(current_user,before:params[:before].present? ? positive_id(:before) : nil,round_id:params[:round_id].present? ? positive_id(:round_id) : nil)
    end
    def play
      RateLimiter.new(current_user,'rsc-games-play',40,1.minute).performed!
      bets=params[:bets]
      bets=bets.map { |b| b.is_a?(ActionController::Parameters) ? b.permit(:choice,:stake).to_h : b } if bets.is_a?(Array)
      render_json_dump Games.start(actor:current_user,game:params.require(:game).to_s,stake:params[:stake],choice:params[:choice]&.to_s,bets:bets,request_id:params.require(:request_id))
    end
    def act
      RateLimiter.new(current_user,'rsc-games-action',90,1.minute).performed!
      version=params.require(:version).to_s
      raise Error.new('game_invalid_action') unless /\A[0-9]{1,5}\z/.match?(version)
      render_json_dump Games.act(actor:current_user,id:positive_id(:id),move:params.require(:move).to_s,version:version.to_i,request_id:params.require(:request_id))
    end
  end
end
