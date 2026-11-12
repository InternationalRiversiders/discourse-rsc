# frozen_string_literal: true
module DiscourseRsc
  class LotteryAutobet
    def self.view(actor)
      plan = LotteryPlan.find_by(user_id: actor.id)
      { selections: plan&.selections || [], version: plan&.version || 0,
        effective_at: plan&.effective_at, last_result: plan&.last_result || {} }
    end

    def self.save(actor:, selections:, version:)
      Lottery.ensure_access!(actor)
      Safety.ensure_writable!
      raise Error.new('lottery_plan_invalid') unless selections.is_a?(Array) && selections.size <= Lottery::LIMIT && version.is_a?(Integer) && version >= 0
      rows = selections.map do |row|
        raise Error.new('lottery_plan_invalid') unless row.is_a?(Hash)
        n, q, on = row.values_at('number', 'quantity', 'enabled')
        raise Error.new('lottery_number') unless n.is_a?(String) && /\A[0-9]{4}\z/.match?(n)
        raise Error.new('lottery_quantity') unless q.is_a?(Integer) && q.between?(1, Lottery::LIMIT)
        raise Error.new('lottery_plan_invalid') unless [true, false].include?(on)
        { 'number'=>n, 'quantity'=>q, 'enabled'=>on }
      end
      raise Error.new('lottery_plan_duplicate') unless rows.map { |r| r['number'] }.uniq.size == rows.size
      raise Error.new('lottery_plan_limit') if rows.select { |r| r['enabled'] }.sum { |r| r['quantity'] } > Lottery::LIMIT
      Lottery.ensure_access!(actor, writable: true) if rows.any? { |r| r['enabled'] }
      LotteryPlan.transaction do
        # Same lock as purchase/settlement: editing and daily execution cannot race.
        Commands.lock('rsc-lottery')
        plan = LotteryPlan.find_or_initialize_by(user_id: actor.id)
        raise Error.new('lottery_plan_changed', status:409) unless plan.version == version
        plan.update!(selections:rows, enabled:rows.any? { |r| r['enabled'] }, version:version+1,
          effective_at:Lottery.next_deadline(Time.current))
      end
      view(actor)
    end

    def self.process
      return if Safety.read_only? || !SiteSetting.rsc_enabled || !SiteSetting.rsc_native_trial_enabled || !SiteSetting.rsc_games_enabled || !SiteSetting.rsc_lottery_enabled
      LotteryPlan.where(enabled:true).find_each do |candidate|
        LotteryPlan.transaction do
          Commands.lock('rsc-lottery')
          plan = LotteryPlan.find_by(id:candidate.id)
          draw = LotteryDraw.find_by(settled_at:nil)
          next unless plan&.enabled && draw && Time.current < draw.draw_at && plan.effective_at <= draw.created_at && plan.last_draw_id != draw.id
          actor = User.find_by(id:plan.user_id)
          next unless actor
          results = plan.selections.select { |r| r['enabled'] }.map do |row|
            begin
              ticket = LotteryTicket.transaction(requires_new:true) do
                raise Error.new('lottery_plan_user_unavailable',status:403) unless actor.active && (!actor.suspended_till || actor.suspended_till <= Time.current)
                Lottery.ensure_access!(actor,writable:true)
                Lottery.purchase!(actor:actor,draw:draw,number:row['number'],quantity:row['quantity'],automatic:true)
              end
              row.slice('number','quantity').merge('status'=>'bought','ticket_id'=>ticket.id)
            rescue Error => e
              # Expected business rejection is final for this draw; infrastructure
              # failures roll back the whole plan, so the next job can retry safely.
              raise if e.status >= 500 || %w[idempotency_conflict lottery_closed].include?(e.code)
              row.slice('number','quantity').merge('status'=>'skipped','reason'=>Error.user_message(e.code))
            end
          end
          plan.update!(last_draw_id:draw.id,last_result:{draw_id:draw.id,draw_at:draw.draw_at,executed_at:Time.current,rows:results})
        end
      end
    end
  end
end
