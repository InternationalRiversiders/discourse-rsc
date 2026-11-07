# frozen_string_literal: true
require 'mini_racer'
module DiscourseRsc
  module Arcade
    NAMES = { '2048'=>'2048', 'blocks'=>'方块堆叠', 'snake'=>'贪吃蛇', 'bird'=>'河畔飞鸟', 'hex'=>'六角消除', 'bricks'=>'打砖块', 'merge'=>'合成大河畔' }.freeze
    PRIZES = [100,60,40,25,15].freeze
    RULES_VERSION = 2
    CHECKPOINT_BATCHES = 64
    SAVE_RETENTION = 30.days
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
    def self.period(now=Time.current)
      latest=ArcadePeriod.where.not(game:nil).order(ordinal: :desc).first
      return latest if latest && latest.starts_at<=now && latest.ends_at>now
      ArcadePeriod.transaction do
        Commands.lock('arcade-rotation')
        latest=ArcadePeriod.where.not(game:nil).order(ordinal: :desc).first
        next latest if latest && latest.starts_at<=now && latest.ends_at>now
        cadence=SiteSetting.rsc_arcade_rotation_cadence=='daily' ? 'daily' : 'weekly'
        duration=cadence=='daily' ? 1.day : 7.days
        if latest
          # No empty rows/jobs for missed seasons during downtime. Rotation
          # advances by elapsed periods; the prior played season still settles.
          steps=((now-latest.ends_at)/duration).floor+1
          starts=latest.ends_at+(steps-1)*duration
          ends=starts+duration
          number=latest.ordinal+steps
          game=NAMES.keys[(NAMES.keys.index(latest.game)+steps)%NAMES.size]
        else
          starts=now;number=1;game=NAMES.keys.first
          if cadence=='daily'
            ends=now.in_time_zone('Asia/Shanghai').beginning_of_day+20.hours
            ends+=1.day if ends<=now
          else
            ends=end_time(now)
            ends+=7.days if ends<now+6.days
          end
          ends+=duration while ArcadePeriod.exists?(ends_at:ends)
        end
        ArcadePeriod.create!(starts_at:starts,ends_at:ends,game:game,cadence:cadence,ordinal:number,
          prizes:SiteSetting.rsc_arcade_rewards_enabled ? PRIZES : [],results:{'rules_version'=>RULES_VERSION})
      end
    end
    def self.period_rules(p)
      RULES_VERSION
    end
    def self.season_view(p)
      { id:p.id,number:p.ordinal,game:p.game,name:NAMES[p.game],starts_at:p.starts_at,ends_at:p.ends_at,
        cadence:p.cadence,prizes:p.prizes,rules_version:period_rules(p),next_game:NAMES.keys[(NAMES.keys.index(p.game)+1)%NAMES.size] }
    end
    def self.catalog(actor)
      access!(actor)
      { protocol:1,rules_version:RULES_VERSION,games:NAMES.map { |id,name| {id:id,name:name} },
        current:season_view(period),server_time:Time.current }
    end
    def self.randoms(n)
      Array.new(n) { SecureRandom.random_number(1_000_000_000) }
    end
    def self.key!(key)
      raise Error.new('invalid_request_id') unless key.is_a?(String) && /\A[A-Za-z0-9_-]{8,100}\z/.match?(key)
    end
    def self.start(actor:, game:, request_id:, rules_version: 1, scope: 'season')
      access!(actor,writable:true);key!(request_id)
      raise Error.new('invalid_game') unless NAMES.key?(game)
      raise Error.new('arcade_upgrade') unless rules_version==RULES_VERSION
      raise Error.new('arcade_invalid_actions') unless %w[all season].include?(scope)
      ArcadeRun.transaction do
        Commands.lock("arcade-start:#{actor.id}")
        previous=ArcadeRun.find_by(user_id:actor.id,start_key:request_id)
        if previous
          raise Error.new('idempotency_conflict',status:409) unless previous.game==game
          raise Error.new('arcade_upgrade') if previous.state['version']>rules_version
          upgrade_save!(previous)
          next view(previous)
        end
        ArcadeRun.where(user_id:actor.id,game:game,status:'playing').where('expires_at <= ?',Time.current).update_all(status:'expired')
        active=ArcadeRun.find_by(user_id:actor.id,game:game,status:'playing')
        if active
          raise Error.new('arcade_upgrade') if active.state['version']>rules_version
          upgrade_save!(active)
          next view(active)
        end
        p=period
        version=RULES_VERSION
        initial=randoms(game=='2048' ? 24 : 20)
        state=engine('create',game,initial,version)
        run=ArcadeRun.create!(user_id:actor.id,period_id:p.id,game:game,start_key:request_id,state:state,inputs:[{'initial'=>initial,'version'=>version}],
          expires_at:Time.current+SAVE_RETENTION)
        view(run)
      end
    end
    # Keep the server-verified position and score when resuming a trial save.
    # Bump the revision so a pre-upgrade client cannot append an old input batch.
    def self.upgrade_save!(run)
      run.with_lock do
        next unless run.status=='playing' && run.state['version']<RULES_VERSION
        state=run.state.deep_dup.merge('version'=>RULES_VERSION,'limit'=>nil)
        state['wave'] ||= 1 if run.game=='bricks'
        digest=Digest::SHA256.hexdigest(JSON.generate(run.inputs))
        run.update!(state:state,version:run.version+1,expires_at:Time.current+SAVE_RETENTION,
          inputs:[{'checkpoint'=>state.deep_dup,'at_version'=>run.version+1,'digest'=>digest}],
          last_key:nil,last_digest:nil)
      end
    end
    def self.advance(actor:, id:, version:, request_id:, frames:, events:, finish: false, rules_version: 1)
      access!(actor,writable:true);key!(request_id)
      raise Error.new('arcade_upgrade') unless rules_version==RULES_VERSION
      raise Error.new('arcade_invalid_actions') unless version.is_a?(Integer) && frames.is_a?(Integer) && [true,false].include?(finish)
      raise Error.new('arcade_invalid_actions') unless events.is_a?(Array) && events.size<=360 && events.all? { |e| e.is_a?(Array) && e.size==2 && e[0].is_a?(Integer) && e[1].is_a?(String) && e[1].bytesize<=10 }
      fingerprint=Digest::SHA256.hexdigest(JSON.generate([version,frames,events,finish]))
      ArcadeRun.transaction do
        run=ArcadeRun.where(user_id:actor.id).find(id)
        # Serialize the final checkpoint with period settlement at the deadline.
        period_lock=Digest::SHA256.digest("arcade-period:#{run.period_id}").unpack1('q>')
        ArcadeRun.connection.execute("SELECT pg_advisory_xact_lock_shared(#{period_lock})")
        run.lock!
        raise Error.new('arcade_version',status:409) unless run.state['version']==RULES_VERSION
        if run.last_key==request_id
          raise Error.new('idempotency_conflict',status:409) unless run.last_digest==fingerprint
          next view(run)
        end
        if run.status=='finished' && run.state['season_closed'] && run.version==version
          run.update!(version:run.version+1,last_key:request_id,last_digest:fingerprint)
          next view(run)
        end
        raise Error.new('arcade_expired',status:409) if run.expires_at<=Time.current || run.status!='playing'
        raise Error.new('arcade_version',status:409) unless run.version==version
        p=ArcadePeriod.find(run.period_id)
        if p.game==run.game && p.ends_at<=Time.current
          run.update!(status:'finished',state:run.state.merge('season_closed'=>true),finished_at:p.ends_at-Rational(1,1_000_000),version:run.version+1,last_key:request_id,last_digest:fingerprint)
          next view(run)
        end
        raise Error.new('arcade_invalid_actions') if frames.zero? && !finish
        state=engine('advance',run.state,frames,events)
        # Only the next bounded window is disclosed; no complete seed ever leaves the server.
        target=20
        refill=randoms([target-state['q'].size,0].max)
        state['q'].concat(refill)
        # An authoritative checkpoint plus a bounded replay tail keeps long saves small.
        # Clients never supply checkpoints; every state transition is verified here.
        if run.state['version']>=2 && run.inputs.length>CHECKPOINT_BATCHES
          digest=Digest::SHA256.hexdigest(JSON.generate(run.inputs))
          run.inputs=[{'checkpoint'=>run.state.deep_dup,'at_version'=>run.version,'digest'=>digest}]
        end
        run.inputs << { 'frames'=>frames, 'events'=>events, 'refill'=>refill }
        run.expires_at=Time.current+SAVE_RETENTION if run.state['version']>=2
        run.state=state;run.score=state['score'];run.version+=1;run.last_key=request_id;run.last_digest=fingerprint
        if finish || state['over']
          run.status='finished';run.finished_at=Time.current
        end
        run.save!;view(run)
      end
    end
    def self.view(run)
      state=run.state.deep_dup
      p=ArcadePeriod.find_by(id:run.period_id)
      season_id=p&.game==run.game && p.starts_at && run.created_at>=p.starts_at ? p.id : nil
      {id:run.id,game:run.game,version:run.version,state:state,status:run.status,expires_at:run.expires_at,
        period_id:run.period_id,season_id:season_id,rules_version:state['version']}
    end
    def self.ranked(p,game)
      return [] if p&.game && p.game!=game
      scope=ArcadeRun.where(game:game,status:'finished').where('score > 0')
      if p
        scope=scope.where(period_id:p.id)
        scope=scope.where('discourse_rsc_arcade_runs.created_at >= ? AND finished_at < ?',p.starts_at,p.ends_at) if p.starts_at
      end
      scope=scope.joins('JOIN users ON users.id = discourse_rsc_arcade_runs.user_id')
        .joins("JOIN discourse_rsc_accounts a ON a.key = 'wallet:' || users.id::text")
        .where("users.active AND (users.suspended_till IS NULL OR users.suspended_till < CURRENT_TIMESTAMP) AND a.status = 'active'")
      scope.group(:user_id).maximum(:score).sort_by { |uid,score| [-score,uid] }
    end
    def self.rank_cache_key(period_id,game)
      "rsc-arcade-rank-v6:#{period_id || 'all'}:#{game}"
    end
    def self.rank_rows(p,game)
      Rails.cache.fetch(rank_cache_key(p&.id,game),expires_in:20.seconds) do
        rank=0;prev=nil
        rows=ranked(p,game).each_with_index.map do |(uid,score),index|
          rank=index+1 if score!=prev;prev=score
          {user_id:uid,score:score,rank:rank}
        end.first(20)
        users=User.where(id:rows.map { |r| r[:user_id] }).index_by(&:id)
        rows.map { |r| r.merge(user:UserIdentity.serialize(users[r[:user_id]])) }
      end
    end
    def self.ranking(actor,game)
      access!(actor);raise Error.new('invalid_game') unless NAMES.key?(game)
      p=period
      season=p.game==game ? season_view(p).merge(rows:rank_rows(p,game)) : nil
      previous=ArcadePeriod.where(game:game).where.not(settled_at:nil).order(ordinal: :desc).first
      { rules_version:RULES_VERSION, rows:rank_rows(nil,game),season:season,featured:season_view(p),
        ends_at:season ? p.ends_at : nil,prizes:season ? p.prizes : [],
        previous:previous ? {number:previous.ordinal,ends_at:previous.ends_at,rows:previous.results.fetch(game,[])} : nil }
    end
    def self.settle
      return if Safety.read_only?
      period if SiteSetting.rsc_arcade_enabled
      ArcadePeriod.where(settled_at:nil).where('ends_at <= ?',Time.current).find_each do |p|
        p.with_lock do
          next if p.settled_at
          Commands.lock("arcade-period:#{p.id}")
          # Bank the last server-verified checkpoint of an unfinished
          # season run. Late client input cannot enter an already closed season.
          if p.game
            ArcadeRun.where(period_id:p.id,game:p.game,status:'playing').find_each do |run|
              run.with_lock { run.update!(status:'finished',state:run.state.merge('season_closed'=>true),finished_at:p.ends_at-Rational(1,1_000_000)) if run.status=='playing' }
            end
          end
          results={'rules_version'=>period_rules(p)};credits=Hash.new(0)
          (p.game ? [p.game] : NAMES.keys).each do |game|
            index=0;rows=[]
            ranked(p,game).chunk { |_,score| score }.each do |score,members|
              rank=index+1
              # Pre-rotation trial periods never award seven games at once.
              prizes=p.game ? p.prizes : []
              budget=(prizes[index,members.size] || []).sum * Amount::UNIT
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
              metadata:{reason: "休闲挑战赛季奖励 · #{NAMES[p.game]}",arcade_period_id:p.id,game:p.game,season_number:p.ordinal})
          end
          p.update!(results:results,settled_at:Time.current)
        end
      end
      ArcadeRun.where(status:'playing').where('expires_at <= ?',Time.current).update_all(status:'expired')
    end
  end
end
