# frozen_string_literal: true
module DiscourseRsc
  module ForecastSettlement
    # Resolution amounts are ratios (currently e.g. [1000000, 0]), not prices.
    # Never infer a payout from last-traded price, closed, or endDate.
    def self.payouts(row)
      values = row && row['payouts']
      return unless row && row['status'] == 'resolved' && row['extended_review'] != true && values.is_a?(Array) && values.size == 2
      return unless values.all? { |v| v.is_a?(Integer) && v >= 0 && v <= 10**18 } && values.sum.positive?
      time = Time.iso8601(row.fetch('resolved_at'))
      return unless time <= Time.current && row['resolved_block'].to_i.positive?
      values
    rescue KeyError, ArgumentError, TypeError
      nil
    end

    def self.observe(market, row)
      return unless row.is_a?(Hash) && row['condition_id'] == market.condition_id
      market.with_lock do
        values = payouts(row)
        if market.settled_at
          if values && values != market.resolution['payouts']
            Audit.create!(action: 'forecast_resolution_changed', details: { market_id: market.id }, created_at: Time.current)
          end
          return
        end
        return if market.state == 'review'
        if values
          digest = Digest::SHA256.hexdigest(JSON.generate([market.condition_id, values, row['resolved_at'], row['resolved_block']]))
          if market.resolution_digest == digest && market.resolution_seen_at && market.resolution_seen_at <= 2.minutes.ago
            market.update!(state: 'resolved', resolution: row, confirmed_at: Time.current)
          else
            market.update!(state: 'awaiting', resolution: row, resolution_digest: digest,
              resolution_seen_at: market.resolution_digest == digest ? market.resolution_seen_at : Time.current, confirmed_at: nil)
          end
        elsif row['status'].present? && !%w[unresolved open].include?(row['status'])
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

    def self.tick
      return unless SiteSetting.rsc_enabled && SiteSetting.rsc_forecast_enabled && SiteSetting.rsc_native_trial_enabled && !Safety.read_only?
      # Across both A/B workers, only one poller owns the cycle.
      DistributedMutex.synchronize('rsc-forecast-sync', validity: 180) do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
        unless Discourse.redis.exists?('rsc:forecast:discovered')
          begin
            ForecastProvider.discover
            Discourse.redis.setex('rsc:forecast:discovered', 600, '1')
          rescue Error => error
            Rails.logger.warn("RSC forecast discovery: #{error.code}")
          end
        end
        # Holdings stay in the settlement watch list after falling out of popular.
        ids = ForecastPosition.where(state: 'open').where('shares_units > 0').select(:market_id)
        scope = ForecastMarket.where(settled_at: nil).where('featured = TRUE OR id IN (?)', ids)
        scope.order(Arel.sql('synced_at ASC NULLS FIRST')).limit(12).each do |market|
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          begin
            ForecastProvider.refresh(market)
            row = ForecastProvider.resolution(market)
            observe(market, row) if row
            settle(market.reload)
          rescue Error => error
            Rails.logger.warn("RSC forecast market=#{market.id}: #{error.code}")
          end
        end
        ForecastQuote.where('expires_at < ?', 1.day.ago).delete_all
      end
    end
  end
end
