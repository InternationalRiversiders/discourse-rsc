# frozen_string_literal: true
module DiscourseRsc
  class Sports
    def self.settle_pending
      Safety.ensure_writable!
      result = { settled: 0, failed: 0 }
      SportMatch.where(status: %w[finished canceled]).joins(:predictions).where(discourse_rsc_predictions: { status: 'pending' }).distinct.pluck(:id).each do |id|
        begin
          result[:settled] += settle(id)
        rescue StandardError => error
          result[:failed] += 1
          Audit.create!(action: 'settlement_failed', details: { match_id: id, error: error.class.name }, created_at: Time.current)
        end
      end
      result
    end
    def self.predict(actor:, match_id:, pick:, stake:, request_id:, prediction_id: nil)
      Access.ensure_member!(actor)
      units = Amount.positive(stake)
      Commands.run(user_id: actor.id, action: "prediction", request_id: request_id,
                   input: [match_id, pick, units.to_s, prediction_id]) do
        match = SportMatch.lock.find(match_id)
        raise Error.new("match_locked", status: 409) unless match.status == "scheduled" && match.starts_at > Time.current
        raise Error.new("invalid_pick") unless %w[home away draw].include?(pick) && (pick != "draw" || match.allow_draw)
        raise Error.new("odds_unavailable", status: 409) unless match.odds_at && match.odds_at >= Time.current - SiteSetting.rsc_odds_max_age_hours.hours
        odds = match.odds[pick]
        raise Error.new("odds_unavailable", status: 409) unless odds && Amount.parse(odds) >= Amount::UNIT
        prediction = Prediction.lock.find_by(user_id: actor.id, sport_match_id: match.id)
        if prediction_id
          raise Error.new("prediction_not_found", status: 404) unless prediction&.id == prediction_id
          raise Error.new("prediction_settled", status: 409) unless prediction.status == "pending"
        elsif prediction
          raise Error.new("prediction_exists", status: 409)
        end
        wallet = Account.wallet(actor.id)
        raise Error.new("wallet_frozen", status: 403) unless wallet.status == "active"
        old_stake = prediction&.stake_units.to_i
        if prediction
          revisions = prediction.revisions + [{ pick: prediction.pick, stake: Amount.format(old_stake), odds: prediction.odds, at: Time.current.iso8601 }]
          prediction.update!(pick: pick, stake_units: units, odds: odds, revisions: revisions)
        else
          prediction = Prediction.create!(user_id: actor.id, sport_match_id: match.id, pick: pick, stake_units: units, odds: odds)
        end
        escrow = Account.internal("prediction:#{prediction.id}")
        difference = units - old_stake
        wallet.lock! if difference.zero?
        raise Error.new("wallet_frozen", status: 403) unless wallet.status == "active"
        unless difference.zero?
          Commands.move(user_id: actor.id, action: "prediction_stake", request_id: request_id,
                        postings: { wallet.id => -difference, escrow.id => difference },
                        metadata: { prediction_id: prediction.id, match_id: match.id, pick: pick, odds: odds })
        end
        { prediction_id: prediction.id, stake: Amount.format(units), potential_payout: Amount.format(units * Amount.parse(odds) / Amount::UNIT) }
      end
    end

    def self.settle(match_id)
      Safety.ensure_writable!
      SportMatch.transaction do
        match = SportMatch.lock.find(match_id)
        next 0 unless %w[finished canceled].include?(match.status)
        if match.status == "finished"
          next 0 unless %w[home away draw].include?(match.result) && match.confirmed_at &&
                        match.confirmed_at <= Time.current - SiteSetting.rsc_sports_settlement_delay_seconds.seconds
        end
        predictions = Prediction.where(sport_match_id: match.id, status: "pending").order(:id).lock.to_a
        predictions.each do |prediction|
          stake = prediction.stake_units.to_i
          refunded = match.status == "canceled"
          won = !refunded && prediction.pick == match.result
          payout = refunded ? stake : (won ? stake * Amount.parse(prediction.odds) / Amount::UNIT : 0)
          status = refunded ? "refunded" : (won ? "won" : "lost")
          escrow = Account.internal("prediction:#{prediction.id}")
          wallet = Account.wallet(prediction.user_id)
          bank = Account.internal("system:sports", kind: "system")
          Commands.move(user_id: prediction.user_id, action: "prediction_settlement",
                        request_id: "prediction-#{prediction.id}",
                        postings: { escrow.id => -stake, wallet.id => payout, bank.id => stake - payout },
                        metadata: { prediction_id: prediction.id, status: status }, settlement: true,
                        event: Commands.event(prediction.user_id, "prediction_settled", { "amount" => Amount.format(payout), "status" => status, "match_id" => match.id, "prediction_id" => prediction.id, "match" => "#{match.home} — #{match.away}" }))
          prediction.update!(status: status, payout_units: payout, settled_at: Time.current)
        end
        predictions.size
      end
    end
  end
end
