# frozen_string_literal: true
module DiscourseRsc
  class ArcadeController < WalletController
    def catalog
      render_json_dump Arcade.catalog(current_user)
    end
    def ranking
      render_json_dump Arcade.ranking(current_user,params[:game].to_s)
    end
    def start
      RateLimiter.new(current_user,'rsc-arcade-start',20,1.minute).performed!
      render_json_dump Arcade.start(actor:current_user,game:params[:game].to_s,request_id:params[:request_id])
    end
    def advance
      id=positive_id(:id)
      game=ArcadeRun.where(id:id,user_id:current_user.id).pick(:game)
      # 2048 intentionally fetches a private server-generated tile every move;
      # realtime games send batches. Don't rate-limit normal rapid swipes as if
      # they were hundreds of multi-frame simulation batches.
      grid=game=='2048'
      RateLimiter.new(current_user,"rsc-arcade-action-#{grid ? 'grid' : 'realtime'}",grid ? 600 : 180,1.minute).performed!
      render_json_dump Arcade.advance(actor:current_user,id:id,version:params[:version],request_id:params[:request_id],
        frames:params[:frames],events:params[:events],finish:params.fetch(:finish,false))
    end
  end
end
