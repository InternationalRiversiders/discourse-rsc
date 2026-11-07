# frozen_string_literal: true
module DiscourseRsc
  class ArcadeController < WalletController
    def ranking
      render_json_dump Arcade.ranking(current_user,params[:game].to_s)
    end
    def start
      RateLimiter.new(current_user,'rsc-arcade-start',20,1.minute).performed!
      render_json_dump Arcade.start(actor:current_user,game:params[:game].to_s,request_id:params[:request_id])
    end
    def advance
      RateLimiter.new(current_user,'rsc-arcade-action',180,1.minute).performed!
      render_json_dump Arcade.advance(actor:current_user,id:positive_id(:id),version:params[:version],request_id:params[:request_id],
        frames:params[:frames],events:params[:events],finish:params.fetch(:finish,false))
    end
  end
end
