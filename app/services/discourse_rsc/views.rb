# frozen_string_literal: true
module DiscourseRsc
  module Views
    def self.position(position)
      instrument=position.instrument;valuation=Valuation.position(position,Valuation.mark(instrument));profit=valuation[:pnl]
      margin=position.margin_units.to_i;equity=profit && [margin+profit,0].max
      {id:position.id,instrument_id:instrument.id,symbol:instrument.symbol,name:instrument.name,side:position.side,leverage:position.leverage,quantity:Amount.format(position.quantity_units),average:Amount.format(position.average_units),margin:Amount.format(margin),pnl:profit && Amount.format(profit),equity:equity && Amount.format(equity),maintenance:Amount.format(margin/4),break_even:Amount.format(TradingRules.break_even(position,instrument.fee_bps)),risk:equity && (equity<=margin/4 ? 'liquidation' : equity<=margin/2 ? 'high' : 'normal'),valuation_basis:valuation[:basis],valuation_at:valuation[:at],take_profit:position.take_profit_units && Amount.format(position.take_profit_units),stop_loss:position.stop_loss_units && Amount.format(position.stop_loss_units),hold_until:position.hold_until,liquidation:Risk.liquidation(position)}
    end

    def self.order(order)
      instrument=order.instrument
      cancel_at=instrument.category=='crypto' ? order.created_at+2.minutes : nil
      cancel_until=instrument.category=='crypto' ? nil : order.created_at+10.seconds
      allowed=order.status=='pending' && (instrument.provider_error.present? || order.details['error'].present? || (order.expires_at && order.expires_at<=Time.current) || (cancel_at ? Time.current>=cancel_at : Time.current<=cancel_until))
      {id:order.id,instrument_id:instrument.id,symbol:instrument.symbol,side:order.side,status:order.status,quantity:Amount.format(order.quantity_units),leverage:order.leverage,reserved:Amount.format(order.reserved_units),created_at:order.created_at,execute_at:order.execute_at,expires_at:order.expires_at,cancel_at:cancel_at,cancel_until:cancel_until,can_cancel:allowed,error_message:order.details['error'].present? && I18n.t("discourse_rsc.errors.#{order.details['error']}",default:order.details['error']),details:order.details.slice('price','fee','pnl','payout','margin','gross','reason','error','reference_price','legacy_status')}
    end

    def self.prediction(item)
      {id:item.id,match_id:item.sport_match_id,match_name:"#{SportsPresentation.team(item.sport_match.home)} — #{SportsPresentation.team(item.sport_match.away)}",pick:item.pick,stake:Amount.format(item.stake_units),odds:item.odds,status:item.status,payout:Amount.format(item.payout_units),potential_payout:Amount.format(item.stake_units.to_i*Amount.parse(item.odds)/Amount::UNIT),created_at:item.created_at,settled_at:item.settled_at}
    end

    def self.matches(user_id, focus: nil)
      own_pending=Prediction.where(user_id:user_id,status:'pending').select(:sport_match_id)
      matches=SportMatch.where("starts_at > ? OR id IN (?)",7.days.ago,own_pending).order(Arel.sql("CASE status WHEN 'live' THEN 0 WHEN 'scheduled' THEN 1 WHEN 'postponed' THEN 2 WHEN 'canceled' THEN 3 ELSE 4 END, starts_at ASC, id ASC")).limit(200).to_a
      # Pending predictions remain accessible even beyond the first 200 fixtures.
      matches=(matches+SportMatch.where(id:own_pending).to_a+SportMatch.where(id:focus).to_a).uniq(&:id)
      own=Prediction.where(user_id:user_id,sport_match_id:matches.map(&:id)).includes(:sport_match).index_by(&:sport_match_id)
      counts=Prediction.where(sport_match_id:matches.map(&:id)).group(:sport_match_id).count
      matches.map do |item|
        reason=if item.status!='scheduled' || item.starts_at<=Time.current; 'match_locked'
          elsif !item.odds_at || item.odds_at<SiteSetting.rsc_odds_max_age_hours.hours.ago || item.odds.empty?; 'odds_unavailable'; end
        {id:item.id,sport:item.sport,league:item.league,league_name:I18n.t("discourse_rsc.leagues.#{item.league.tr('.', '_')}",default:item.league),stage:SportsPresentation.stage(item.provider_data['stage']),venue:item.provider_data['venue'],status_detail:SportsPresentation.status_detail(item.provider_data['status_detail']),home:item.home,away:item.away,home_name:SportsPresentation.team(item.home),away_name:SportsPresentation.team(item.away),home_logo:SportsPresentation.logo(item.provider_data,'home',item.home),away_logo:SportsPresentation.logo(item.provider_data,'away',item.away),starts_at:item.starts_at,status:item.status,allow_draw:item.allow_draw,odds:item.odds,odds_at:item.odds_at,score:item.score,participants:counts.fetch(item.id,0),locked_reason:reason,prediction:own[item.id] && prediction(own[item.id])}
      end
    end

    def self.packet(item,user_id)
      claims=item.claims.to_a;mine=claims.find { |c| c.user_id==user_id }
      remaining=item.status=='open' ? item.total_units.to_i-claims.sum { |c| c.units.to_i } : 0
      {token:item.token,message:item.message,mode:item.mode,status:item.status,total:Amount.format(item.total_units),remaining:Amount.format(remaining),minimum:item.minimum_units && Amount.format(item.minimum_units),maximum:item.maximum_units && Amount.format(item.maximum_units),count:item.claim_limit || item.allocations.size,claimed_count:claims.size,sender:User.find_by(id:item.user_id)&.username,sender_user:UserIdentity.serialize(item.user_id),expires_at:item.expires_at,created_at:item.created_at,claimed:!!mine,own:item.user_id==user_id,my_amount:mine && Amount.format(mine.units)}
    end
  end
end
