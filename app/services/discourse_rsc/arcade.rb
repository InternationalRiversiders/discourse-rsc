# frozen_string_literal: true
require 'mini_racer'
module DiscourseRsc
  module Arcade
    NAMES = { '2048'=>'2048', 'blocks'=>'方块堆叠', 'snake'=>'贪吃蛇', 'bird'=>'河畔飞鸟', 'hex'=>'六角消除', 'bricks'=>'打砖块', 'merge'=>'合成大河畔' }.freeze
    PRIZES = [100,60,40,25,15].freeze
    CORE = File.read(File.expand_path('../../../assets/javascripts/discourse/lib/arcade-core.js', __dir__)).sub('export default ArcadeCore;', 'globalThis.ArcadeCore = ArcadeCore;').freeze
    def self.access!(actor, writable: false)
      Games.ensure_access!(actor, writable: writable)
      raise Error.new('arcade_disabled',status:503) unless SiteSetting.rsc_arcade_enabled
    end
    def self.engine(method, *args)
      context=MiniRacer::Context.new(timeout: 750, max_memory: 24*1024*1024)
      context.eval(CORE)
      context.eval("ArcadeCore.#{method}(...#{JSON.generate(args)})")
    rescue MiniRacer::RuntimeError, MiniRacer::ScriptTerminatedError
      raise Error.new('arcade_invalid_actions')
    ensure
      context&.dispose
    end
    def self.end_time(now=Time.current)
      local=now.in_time_zone('Asia/Shanghai')
      candidate=local.beginning_of_day + ((7-local.wday)%7).days + 20.hours
      candidate+=7.days if candidate<=local
      candidate.utc
    end
    def self.period
      ends=end_time
      ArcadePeriod.create_or_find_by!(ends_at:ends) { |p| p.prizes=SiteSetting.rsc_arcade_rewards_enabled ? PRIZES : [] }
    end
    def self.randoms(n)
      Array.new(n) { SecureRandom.random_number(1_000_000_000) }
    end
    def self.key!(key)
      raise Error.new('invalid_request_id') unless key.is_a?(String) && /\A[A-Za-z0-9_-]{8,100}\z/.match?(key)
    end
    def self.start(actor:, game:, request_id:)
      access!(actor,writable:true);key!(request_id)
      raise Error.new('invalid_game') unless NAMES.key?(game)
      ArcadeRun.transaction do
        Commands.lock("arcade-start:#{actor.id}")
        previous=ArcadeRun.find_by(user_id:actor.id,start_key:request_id)
        if previous
          raise Error.new('idempotency_conflict',status:409) unless previous.game==game
          next view(previous)
        end
        ArcadeRun.where(user_id:actor.id,game:game,status:'playing').where('expires_at <= ?',Time.current).update_all(status:'expired')
        active=ArcadeRun.find_by(user_id:actor.id,game:game,status:'playing')
        next view(active) if active
        p=period
        initial=randoms(game=='2048' ? 8 : 20)
        state=engine('create',game,initial)
        run=ArcadeRun.create!(user_id:actor.id,period_id:p.id,game:game,start_key:request_id,state:state,inputs:[{'initial'=>initial,'version'=>1}],
          expires_at:[Time.current+2.hours,p.ends_at].min)
        view(run)
      end
    end
    def self.advance(actor:, id:, version:, request_id:, frames:, events:, finish: false)
      access!(actor,writable:true);key!(request_id)
      raise Error.new('arcade_invalid_actions') unless version.is_a?(Integer) && frames.is_a?(Integer) && [true,false].include?(finish)
      raise Error.new('arcade_invalid_actions') unless events.is_a?(Array) && events.size<=360 && events.all? { |e| e.is_a?(Array) && e.size==2 && e[0].is_a?(Integer) && e[1].is_a?(String) && e[1].bytesize<=10 }
      fingerprint=Digest::SHA256.hexdigest(JSON.generate([version,frames,events,finish]))
      ArcadeRun.transaction do
        run=ArcadeRun.where(user_id:actor.id).find(id)
        # Serialize the final checkpoint with period settlement at the deadline.
        period_lock=Digest::SHA256.digest("arcade-period:#{run.period_id}").unpack1('q>')
        ArcadeRun.connection.execute("SELECT pg_advisory_xact_lock_shared(#{period_lock})")
        run.lock!
        if run.last_key==request_id
          raise Error.new('idempotency_conflict',status:409) unless run.last_digest==fingerprint
          next view(run)
        end
        raise Error.new('arcade_expired',status:409) if run.expires_at<=Time.current || run.status!='playing'
        raise Error.new('arcade_version',status:409) unless run.version==version
        raise Error.new('arcade_invalid_actions') if frames.zero? && !finish
        state=engine('advance',run.state,frames,events)
        # Only the next bounded window is disclosed; no complete seed ever leaves the server.
        target=run.game=='2048' ? 4 : 20
        refill=randoms([target-state['q'].size,0].max)
        state['q'].concat(refill)
        run.inputs << { 'frames'=>frames, 'events'=>events, 'refill'=>refill }
        run.state=state;run.score=state['score'];run.version+=1;run.last_key=request_id;run.last_digest=fingerprint
        if finish || state['over']
          run.status='finished';run.finished_at=Time.current
        end
        run.save!;view(run)
      end
    end
    def self.view(run)
      state=run.state.deep_dup
      state.delete('q') if run.game=='2048'
      {id:run.id,game:run.game,version:run.version,state:state,status:run.status,expires_at:run.expires_at,period_id:run.period_id}
    end
    def self.ranked(p,game)
      # Best score per member; admins, suspended accounts and frozen wallets are not prize candidates.
      ArcadeRun.where(period_id:p.id,game:game,status:'finished').where('score > 0')
        .joins('JOIN users ON users.id = discourse_rsc_arcade_runs.user_id')
        .joins("JOIN discourse_rsc_accounts a ON a.key = 'wallet:' || users.id::text")
        .where("users.active AND NOT users.admin AND (users.suspended_till IS NULL OR users.suspended_till < CURRENT_TIMESTAMP) AND a.status = 'active'")
        .group(:user_id).maximum(:score).sort_by { |uid,score| [-score,uid] }
    end
    def self.ranking(actor,game)
      access!(actor);raise Error.new('invalid_game') unless NAMES.key?(game)
      p=period
      data=Rails.cache.fetch("rsc-arcade-rank:#{p.id}:#{game}",expires_in:20.seconds) do
        rank=0;prev=nil
        rows=ranked(p,game).each_with_index.map do |(uid,score),index|
          rank=index+1 if score!=prev;prev=score
          {user_id:uid,score:score,rank:rank}
        end
        selected=rows.first(20)
        users=User.where(id:selected.map { |r| r[:user_id] }).index_by(&:id)
        selected.map { |r| r.merge(user:UserIdentity.serialize(users[r[:user_id]])) }
      end
      { ends_at:p.ends_at,prizes:p.prizes,rows:data,previous:ArcadePeriod.where.not(settled_at:nil).order(ends_at: :desc).first&.results&.fetch(game,[]) || [] }
    end
    def self.settle
      return if Safety.read_only?
      ArcadePeriod.where(settled_at:nil).where('ends_at <= ?',Time.current).find_each do |p|
        p.with_lock do
          next if p.settled_at
          Commands.lock("arcade-period:#{p.id}")
          results={};credits=Hash.new(0)
          NAMES.each_key do |game|
            index=0;rows=[]
            ranked(p,game).chunk { |_,score| score }.each do |score,members|
              rank=index+1
              budget=(p.prizes[index,members.size] || []).sum * Amount::UNIT
              each=budget/members.size
              members.each do |uid,_|
                credits[Account.wallet(uid).id]+=each if each.positive?
                rows << {user_id:uid,score:score,rank:rank,prize:Amount.format(each)} if rank<=20
              end
              index+=members.size
              break if index>=20 && index>=p.prizes.size
            end
            results[game]=rows
          end
          total=credits.values.sum
          if total.positive?
            Ledger.post(operation:'arcade_prize',actor_user_id:0,request_id:"arcade-period-#{p.id}",
              postings:credits.merge(Account.issuance.id=>-total),settlement:true,
              metadata:{reason:'休闲挑战每周排名奖励',arcade_period_id:p.id})
          end
          p.update!(results:results,settled_at:Time.current)
        end
      end
      ArcadeRun.where(status:'playing').where('expires_at <= ?',Time.current).update_all(status:'expired')
    end
  end
end
