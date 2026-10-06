# frozen_string_literal: true
module DiscourseRsc
  module ForecastSettlement
    # Native V2/CTF rows carry payouts and block finality. UMA rows instead
    # carry the oracle's FINAL fixed-point settlement price and event provenance.
    # This is not a traded price or a Gamma outcomePrices probability.
    UMA_PAYOUTS = { '0' => [0, 1], '500000000000000000' => [1, 1],
                    '1000000000000000000' => [1, 0] }.freeze
    def self.payouts(row)
      return unless row.is_a?(Hash) && row['status'] == 'resolved' && row['extended_review'] == false
      if row['payouts'].nil?
        values = UMA_PAYOUTS[row['price']]
        return unless values && %w[condition_id question_id transaction_hash].all? { |key| /\A0x[0-9a-fA-F]{64}\z/.match?(row[key].to_s) }
        return unless /\A[0-9]+\z/.match?(row['log_index'].to_s)
        stamp = row.fetch('last_update_timestamp')
        time = /\A[0-9]+\z/.match?(stamp.to_s) ? Time.at(Integer(stamp)).utc : Time.iso8601(stamp)
      else
        values = row['payouts']
        return unless values.is_a?(Array) && values.size == 2
        return unless values.all? { |v| v.is_a?(Integer) && v >= 0 && v <= 10**18 } && values.sum.positive?
        time = Time.iso8601(row.fetch('resolved_at'))
        return unless row['resolved_block'].is_a?(Integer) && row['resolved_block'].positive?
      end
      return unless time > Time.at(0) && time <= Time.current
      values
    rescue KeyError, ArgumentError, TypeError, RangeError
      nil
    end

    def self.resolution_identity(row, values)
      provenance = row['payouts'].nil? ? row.values_at('question_id', 'transaction_hash', 'log_index', 'last_update_timestamp') : row.values_at('resolved_at', 'resolved_block')
      Digest::SHA256.hexdigest(JSON.generate([row['condition_id'], values, provenance]))
    end

    def self.observe(market, row)
      return unless row.is_a?(Hash) && row['condition_id'] == market.condition_id
      market.with_lock do
        values = payouts(row)
        if market.settled_at
          if values && values != payouts(market.resolution)
            Audit.create!(action: 'forecast_resolution_changed', details: { market_id: market.id }, created_at: Time.current)
          end
          return
        end
        return if market.state == 'review'
        if values
          digest = resolution_identity(row, values)
          if market.resolution_digest == digest && market.resolution_seen_at && market.resolution_seen_at <= 2.minutes.ago
            market.update!(state: 'resolved', resolution: row, confirmed_at: Time.current)
          else
            market.update!(state: 'awaiting', resolution: row, resolution_digest: digest,
              resolution_seen_at: market.resolution_digest == digest ? market.resolution_seen_at : Time.current, confirmed_at: nil)
          end
        # An unfamiliar final-result shape must be visible to operators.
        # UMA's initialized question is 'posed', distinct from a proposed result.
        elsif row['extended_review'] == true || !%w[posed unresolved open].include?(row['status'])
          if row['status'] == 'resolved' && market.resolution != row
            Rails.logger.warn("RSC forecast market=#{market.id}: unsupported_resolution")
          end
          market.update!(state: 'awaiting', resolution: row, resolution_digest: nil, resolution_seen_at: nil, confirmed_at: nil)
        else
          market.update!(resolution: row, resolution_digest: nil, resolution_seen_at: nil, confirmed_at: nil)
        end
      end
    end

    def self.settle(market)
      Safety.ensure_writable!
      market.with_lock do
        next 0 if market.settled_at || market.state != 'resolved' || !market.confirmed_at
        values = payouts(market.resolution)
        next 0 unless values
        positions = ForecastPosition.where(market_id: market.id, state: 'open').where('shares_units > 0').order(:id).lock.to_a
        positions.each do |position|
          shares, cost = position.shares_units.to_i, position.cost_units.to_i
          payout = shares * values.fetch(position.outcome) / values.sum
          escrow = Account.internal("forecast:#{position.id}")
          wallet = Account.wallet(position.user_id)
          bank = Account.internal('system:forecast', kind: 'system')
          journal = Commands.move(user_id: position.user_id, action: 'forecast_settlement', request_id: "forecast-settle-#{position.id}",
            postings: { escrow.id => -cost, wallet.id => payout, bank.id => cost - payout }, settlement: true,
            metadata: { forecast_market_id: market.id, question: market.question, outcome: market.outcomes[position.outcome] },
            event: Commands.event(position.user_id, 'forecast_settled', { 'amount' => Amount.format(payout), 'match' => market.question,
              'forecast_market_id' => market.id }))
          ForecastTrade.create!(market_id: market.id, user_id: position.user_id, journal_id: journal.id, outcome: position.outcome,
            side: 'settlement', shares_units: shares, cash_units: payout, pnl_units: payout - cost)
          position.update!(state: 'settled', cost_units: 0, realized_units: position.realized_units.to_i + payout - cost)
        end
        market.update!(settled_at: Time.current)
        positions.size
      end
    end

    def self.enabled?
      SiteSetting.rsc_enabled && SiteSetting.rsc_forecast_enabled && SiteSetting.rsc_native_trial_enabled && !Safety.read_only?
    end

    # Once a day, enqueue EVERY watched market, not just the first 12.
    # Spread requests out so a large daily batch does not burst the provider.
    def self.tick
      return unless enabled?
      DistributedMutex.synchronize('rsc-forecast-daily', validity: 180) do
        ids = ForecastPosition.where(state: 'open').where('shares_units > 0').select(:market_id)
        scope = ForecastMarket.where(settled_at: nil).where('featured = TRUE OR id IN (?) OR id IN (?)', ids, ForecastRequest.approved_markets)
        market_ids = scope.order(Arel.sql("CASE WHEN id IN (#{ids.to_sql}) THEN 0 ELSE 1 END, synced_at ASC NULLS FIRST")).pluck(:id)
        market_ids.each_with_index do |id, index|
          Jobs.enqueue_in(index * 5.seconds, :discourse_rsc_forecast_refresh, market_id: id)
        end
        ForecastQuote.where('expires_at < ?', 1.day.ago).delete_all
        market_ids.size
      end
    end

    def self.refresh_market(id, confirm: false)
      return unless enabled?
      DistributedMutex.synchronize("rsc-forecast-market:#{id}", validity: 60) do
        market = ForecastMarket.find_by(id: id)
        return unless market && !market.settled_at
        ForecastProvider.refresh(market)
        row = ForecastProvider.resolution(market)
        observe(market, row) if row
        settle(market.reload)
        # A final result first seen today gets one follow-up in this same batch,
        # rather than making winners wait another full day for confirmation.
        if !confirm && !market.settled_at && market.state == 'awaiting' && market.resolution_seen_at && payouts(market.resolution)
          Jobs.enqueue_in(125.seconds, :discourse_rsc_forecast_refresh, market_id: id, confirm: true)
        end
      end
    end
  end
end
