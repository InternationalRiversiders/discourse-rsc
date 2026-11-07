# frozen_string_literal: true
module DiscourseRsc
  class Lottery
    PRICE = 5
    CONTRIBUTION = 4
    LIMIT = 20
    SEED = 5000
    RESTART_SEED = 3000
    SMALL_PRIZES = { 2 => 10, 3 => 100 }.freeze

    def self.ensure_access!(actor, writable: false)
      Games.ensure_access!(actor, writable: writable)
      raise Error.new('lottery_disabled', status: 503) unless SiteSetting.rsc_lottery_enabled
    end

    # 20:00 Asia/Shanghai = 12:00 UTC; never depends on server/browser timezone.
    def self.next_deadline(now)
      utc = now.utc
      today = Time.utc(utc.year, utc.month, utc.day, 12)
      today > now ? today : today + 1.day
    end

    def self.tick
      return if Safety.read_only? || !SiteSetting.rsc_games_enabled || !SiteSetting.rsc_lottery_enabled
      LotteryDraw.transaction do
        Commands.lock('rsc-lottery')
        pool = Account.internal('lottery:pool')
        seed_key = 'lottery_seed:0:lottery-initial-5000'
        unless Journal.exists?(request_key: seed_key)
          Ledger.post(operation: 'lottery_seed', actor_user_id: 0, request_id: 'lottery-initial-5000',
            postings: { Account.issuance.id => -SEED * Amount::UNIT, pool.id => SEED * Amount::UNIT },
            metadata: { reason: 'Riverside 大乐透初始奖池' })
        end
        now = Time.current
        draw = LotteryDraw.find_by(settled_at: nil)
        settle!(draw, pool) if draw && draw.draw_at <= now
        unless LotteryDraw.exists?(settled_at: nil)
          LotteryDraw.create!(draw_at: next_deadline(Time.current))
        end
      end
    end

    def self.buy(actor:, draw_id:, number:, quantity:, request_id:)
      ensure_access!(actor, writable: true)
      raise Error.new('lottery_number') unless number.is_a?(String) && /\A[0-9]{4}\z/.match?(number)
      raise Error.new('lottery_quantity') unless quantity.is_a?(Integer) && quantity.between?(1, LIMIT)
      tick
      result = Commands.run(user_id: actor.id, action: 'lottery_buy', request_id: request_id,
                            input: [draw_id, number, quantity]) do
        Commands.lock('rsc-lottery')
        draw = LotteryDraw.find_by(id: draw_id, settled_at: nil)
        # Check after acquiring the draw lock. A request queued before the cutoff
        # must not buy into a draw that has already closed or been settled.
        raise Error.new('lottery_closed', status: 409) unless draw && Time.current < draw.draw_at
        count = LotteryTicket.where(draw_id: draw.id, user_id: actor.id).sum(:quantity)
        raise Error.new('lottery_limit', status: 409) if count + quantity > LIMIT
        ticket = LotteryTicket.create!(draw_id: draw.id, user_id: actor.id, number: number, quantity: quantity)
        Ledger.post(operation: 'lottery_ticket', actor_user_id: actor.id, request_id: "lottery-ticket-#{ticket.id}",
          postings: { Account.wallet(actor.id).id => -quantity * PRICE * Amount::UNIT,
            Account.internal('lottery:pool').id => quantity * CONTRIBUTION * Amount::UNIT,
            Account.internal('system:lottery', kind: 'system').id => quantity * (PRICE - CONTRIBUTION) * Amount::UNIT },
          metadata: { lottery_draw_id: draw.id, lottery_ticket_id: ticket.id, number: number, quantity: quantity, reason: 'Riverside 大乐透购票' })
        { ticket_id: ticket.id }
      end
      { ticket: ticket_view(LotteryTicket.includes(:draw).find_by!(id: result.fetch('ticket_id'), user_id: actor.id)),
        replayed: result['replayed'], balance: Account.wallet_snapshot(actor.id).balance }
    end

    def self.matches(number, result)
      number.chars.zip(result.chars).count { |a, b| a == b }
    end

    def self.settle!(draw, pool)
      number = SecureRandom.random_number(10_000).to_s.rjust(4, '0')
      tickets = LotteryTicket.where(draw_id: draw.id).order(:id).to_a
      grouped = tickets.group_by { |t| matches(t.number, number) }
      winners = grouped.fetch(4, [])
      count = winners.sum(&:quantity)
      available = pool.reload.balance_units.to_i
      small = tickets.filter_map do |ticket|
        amount = SMALL_PRIZES[matches(ticket.number, number)]
        [ticket, amount * Amount::UNIT] if amount
      end
      due = small.sum { |t, amount| amount * t.quantity }
      # Calculate per winning entry, then multiply quantity: splitting a purchase
      # into multiple requests must never change its share of a depleted pool.
      prizes = small.to_h do |ticket, per_entry|
        per_entry = per_entry * available / due if due > available
        [ticket, per_entry * ticket.quantity]
      end
      small_paid = prizes.values.sum
      per_jackpot = count.positive? ? (available - small_paid) / count : 0
      winners.each { |ticket| prizes[ticket] = per_jackpot * ticket.quantity }
      credits = Hash.new(0)
      prizes.each do |ticket, prize|
        ticket.update!(payout_units: prize)
        credits[Account.wallet(ticket.user_id).id] += prize if prize.positive?
      end
      paid = credits.values.sum
      if paid.positive?
        Ledger.post(operation: 'lottery_prize', actor_user_id: 0, request_id: "lottery-draw-#{draw.id}",
          postings: credits.merge(pool.id => -paid), settlement: true,
          metadata: { lottery_draw_id: draw.id, number: number, reason: 'Riverside 大乐透中奖' })
      end
      draw.update!(number: number, settled_at: Time.current, winning_tickets: count,
        pool_units: available, paid_units: paid, small_paid_units: small_paid)
      if count.positive?
        Ledger.post(operation: 'lottery_seed', actor_user_id: 0, request_id: "lottery-restart-#{draw.id}",
          postings: { Account.issuance.id => -RESTART_SEED * Amount::UNIT, pool.id => RESTART_SEED * Amount::UNIT },
          metadata: { lottery_draw_id: draw.id, reason: 'Riverside 大乐透下一期底池' })
      end
    end
    private_class_method :settle!

    # Read-only and cheap enough for the games entrance; the scheduled job owns
    # initialization/settlement, not every visit to the games lobby.
    def self.summary
      return nil unless SiteSetting.rsc_lottery_enabled
      draw = LotteryDraw.find_by(settled_at: nil)
      { draw_at: draw&.draw_at, pool: Account.find_by(key: 'lottery:pool')&.balance || '0' }
    end

    def self.accounting
      revenue = LotteryTicket.sum(:quantity) * PRICE * Amount::UNIT
      fees = Account.find_by(key: 'system:lottery')&.balance_units.to_i
      seed_journals = Journal.where(operation: 'lottery_seed').select(:id)
      subsidies = -Entry.where(journal_id: seed_journals, account_id: Account.find_by(key: 'system:issuance')&.id).sum(:units).to_i
      small = LotteryDraw.sum(:small_paid_units).to_i
      paid = LotteryDraw.sum(:paid_units).to_i
      { revenue: revenue, fees: fees, subsidies: subsidies, small_prizes: small,
        jackpots: paid - small, pool: Account.find_by(key: 'lottery:pool')&.balance_units.to_i,
        net_recovered: fees - subsidies }.transform_values { |units| Amount.format(units) }
    end

    def self.ticket_view(ticket)
      { id: ticket.id, draw_id: ticket.draw_id, number: ticket.number, quantity: ticket.quantity,
        created_at: ticket.created_at, draw_at: ticket.draw.draw_at, settled: ticket.draw.settled_at.present?,
        matches: ticket.draw.number && matches(ticket.number, ticket.draw.number), payout: Amount.format(ticket.payout_units) }
    end

    def self.state(actor)
      ensure_access!(actor)
      tick
      draw = LotteryDraw.find_by(settled_at: nil)
      wallet = Account.wallet_snapshot(actor.id)
      { balance: wallet.balance, wallet_status: wallet.status, read_only: Safety.read_only?, price: PRICE,
        contribution: CONTRIBUTION, limit: LIMIT,
        accounting: Access.admin?(actor) ? accounting : nil,
        current: draw && { id: draw.id, draw_at: draw.draw_at, pool: Account.find_by(key: 'lottery:pool')&.balance || '0',
          tickets: LotteryTicket.where(draw_id: draw.id).sum(:quantity),
          mine: LotteryTicket.where(draw_id: draw.id, user_id: actor.id).sum(:quantity) },
        mine: LotteryTicket.where(user_id: actor.id).includes(:draw).order(id: :desc).limit(100).map { |t| ticket_view(t) },
        history: LotteryDraw.where.not(settled_at: nil).order(id: :desc).limit(30).map { |d|
          { id: d.id, draw_at: d.draw_at, number: d.number, winners: d.winning_tickets,
            pool: Amount.format(d.pool_units), paid: Amount.format(d.paid_units),
            small_paid: Amount.format(d.small_paid_units), jackpot: Amount.format(d.paid_units.to_i - d.small_paid_units.to_i) }
        } }
    end
  end
end
