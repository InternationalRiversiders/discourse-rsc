# frozen_string_literal: true
require 'securerandom'
module DiscourseRsc
  class Games
    NAMES = { 'slots'=>'转转乐', 'roulette'=>'幸运转盘', 'scratch'=>'刮刮乐', 'blackjack'=>'21点', 'coin'=>'抛硬币', 'dice'=>'猜骰子' }.freeze
    RED = [1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36].freeze
    SYMBOLS = %w[cherry lemon bell clover diamond seven].freeze
    SLOT_PAY = [2,3,5,7,20,40].freeze
    SCRATCH = [[0,5000],[1,2000],[2,2700],[5,240],[10,50],[50,9],[250,1]].freeze
    ROULETTE_CHOICES = (%w[red black odd even low high dozen1 dozen2 dozen3 column1 column2 column3] + (0..36).map { |n| "n#{n}" }).freeze

    def self.ensure_access!(actor, writable: false)
      Access.ensure_member!(actor)
      raise Error.new('games_disabled',status:503) unless SiteSetting.rsc_games_enabled
      if writable
        Safety.ensure_writable!
        raise Error.new('wallet_frozen',status:403) unless Account.wallet(actor.id).status=='active'
      end
    end

    def self.amount(value)
      units=Amount.positive(value,decimals:2)
      raise Error.new('game_stake_range',details:{max:SiteSetting.rsc_games_max_stake}) unless units.between?(Amount::UNIT/100,SiteSetting.rsc_games_max_stake*Amount::UNIT)
      units
    end

    def self.start(actor:,game:,stake:,choice:,bets:,request_id:)
      ensure_access!(actor,writable:true)
      raise Error.new('invalid_game') unless NAMES.key?(game)
      wager=amount(stake) unless game=='roulette'
      normalized=[]
      if game=='roulette'
        raise Error.new('game_invalid_bet') unless bets.is_a?(Array) && bets.size.between?(1,49)
        normalized=bets.map do |bet|
          raise Error.new('game_invalid_bet') unless bet.is_a?(Hash) && ROULETTE_CHOICES.include?(bet['choice'])
          { 'choice'=>bet['choice'],'stake'=>Amount.format(amount(bet['stake'])) }
        end.sort_by { |b| b['choice'] }
        raise Error.new('game_invalid_bet') unless normalized.map { |b| b['choice'] }.uniq.size==normalized.size
        wager=amount(Amount.format(normalized.sum { |b| Amount.parse(b['stake']) }))
      end
      raise Error.new('game_invalid_bet') if game=='coin' && !%w[heads tails].include?(choice)
      raise Error.new('game_invalid_bet') if game=='dice' && !%w[small big].include?(choice)
      result=Commands.run(user_id:actor.id,action:'game_start',request_id:request_id,input:[game,wager.to_s,choice,normalized]) do
        Commands.lock("rsc-games:#{actor.id}")
        raise Error.new('game_resume',status:409) if game=='blackjack' && GameRound.where(user_id:actor.id,status:'playing').exists?
        # Instant games never remain playing past this transaction, so permit
        # them alongside an existing blackjack hand without changing its cards.
        round=GameRound.create!(user_id:actor.id,game:game,status:game=='blackjack' ? 'playing' : 'settled',stake_units:wager,
          state:{'choice'=>choice,'bets'=>normalized,'rules_version'=>3})
        reserve(round,actor,wager,'open')
        if game=='blackjack'
          deck=shuffle((0...312).map { |n| n%52 })
          round.state.merge!('player'=>[deck.pop,deck.pop],'dealer'=>[deck.pop,deck.pop],'deck'=>deck)
          player_natural=score(round.state['player'])==21
          dealer_natural=score(round.state['dealer'])==21
          if player_natural || dealer_natural
            payout=player_natural ? (dealer_natural ? wager : wager*5/2) : 0
            settle(round,payout,player_natural && !dealer_natural ? 'blackjack' : payout==wager ? 'push' : 'lose')
          else
            round.save!
          end
        else
          payout=instant(round)
          settle(round,payout,payout>wager ? 'win' : payout==wager ? 'push' : 'lose')
        end
        {round_id:round.id}
      end
      view(GameRound.find_by!(id:result.fetch('round_id'),user_id:actor.id)).merge(balance:Account.wallet_snapshot(actor.id).balance,replayed:result['replayed'])
    end

    def self.act(actor:,id:,move:,version:,request_id:)
      ensure_access!(actor,writable:true)
      raise Error.new('game_invalid_action') unless %w[hit stand double].include?(move) && version.is_a?(Integer) && version>=0
      result=Commands.run(user_id:actor.id,action:'game_action',request_id:request_id,input:[id,move,version]) do
        Commands.lock("rsc-games:#{actor.id}")
        round=GameRound.lock.find_by!(id:id,user_id:actor.id)
        raise Error.new('game_finished',status:409) unless round.game=='blackjack' && round.status=='playing'
        raise Error.new('game_changed',status:409) unless round.version==version
        state=round.state
        if move=='double'
          raise Error.new('game_invalid_action') unless state['player'].size==2
          reserve(round,actor,round.stake_units.to_i,'double')
          round.stake_units=round.stake_units.to_i*2
          state['doubled']=true
        end
        state['player'] << state['deck'].pop if %w[hit double].include?(move)
        if score(state['player'])>21
          settle(round,0,'bust')
        elsif move!='hit' || score(state['player'])==21
          state['dealer'] << state['deck'].pop while score(state['dealer'])<17
          player=score(state['player']); dealer=score(state['dealer'])
          payout=dealer>21 || player>dealer ? round.stake_units.to_i*2 : player==dealer ? round.stake_units.to_i : 0
          settle(round,payout,payout.zero? ? 'lose' : payout==round.stake_units.to_i ? 'push' : 'win')
        else
          round.version+=1
          round.save!
        end
        {round_id:round.id}
      end
      view(GameRound.find_by!(id:result.fetch('round_id'),user_id:actor.id)).merge(balance:Account.wallet_snapshot(actor.id).balance,replayed:result['replayed'])
    end

    def self.reserve(round,actor,units,suffix)
      Ledger.post(operation:'game_stake',actor_user_id:actor.id,request_id:"game-#{round.id}-#{suffix}",
        postings:{Account.wallet(actor.id).id=>-units,Account.internal("game:#{round.id}").id=>units},
        metadata:{game_round_id:round.id,game:round.game,reason:NAMES.fetch(round.game)})
    end

    def self.settle(round,payout,result)
      escrow=Account.find_by!(key:"game:#{round.id}")
      wallet=Account.wallet(round.user_id); house=Account.internal('system:games',kind:'system')
      stake=round.stake_units.to_i
      raise Error.new('game_accounting_error',status:500) unless escrow.balance_units.to_i==stake
      postings={escrow.id=>-stake,wallet.id=>payout,house.id=>stake-payout}.reject { |_,n| n.zero? }
      Ledger.post(operation:'game_settlement',actor_user_id:round.user_id,request_id:"game-#{round.id}-settle",postings:postings,
        metadata:{game_round_id:round.id,game:round.game,reason:NAMES.fetch(round.game)},settlement:true)
      round.state['result']=result
      round.state.delete('deck')
      round.status='settled'; round.payout_units=payout; round.settled_at=Time.current; round.version+=1; round.save!
    end

    def self.instant(round)
      state=round.state; stake=round.stake_units.to_i
      case round.game
      when 'coin'
        state['landed']=SecureRandom.random_number(2).zero? ? 'heads' : 'tails'
        state['landed']==state['choice'] ? stake*2 : 0
      when 'dice'
        dice=Array.new(3) { SecureRandom.random_number(6)+1 }; state['dice']=dice
        state['total']=dice.sum
        win=dice.uniq.size>1 && (state['choice']=='small' ? (4..10).cover?(dice.sum) : (11..17).cover?(dice.sum))
        dice.uniq.size==1 ? stake : win ? stake*2 : 0
      when 'slots'
        reels=Array.new(3) { SecureRandom.random_number(SYMBOLS.size) }
        state['symbols']=reels.map { |n| SYMBOLS[n] }
        multiplier=reels.uniq.size==1 ? SLOT_PAY[reels[0]] : reels.uniq.size==2 ? 1.5 : 0
        state['multiplier']=multiplier
        # Half-unit payouts use integer arithmetic, never floating-point money.
        reels.uniq.size==2 ? stake*3/2 : stake*multiplier
      when 'scratch'
        # One paid card, ten independent spots. All money remains integer units.
        spot_stake=stake/10
        state['rules_version']=3
        state['spot_stake']=Amount.format(spot_stake)
        state['spots']=Array.new(10) do
          ticket=SecureRandom.random_number(10000); running=0
          multiplier=SCRATCH.find { |_,weight| running+=weight; ticket<running }.first
          { 'multiplier'=>multiplier, 'payout'=>Amount.format(spot_stake*multiplier) }
        end
        state['spots'].sum { |spot| Amount.parse(spot['payout']) }
      when 'roulette'
        number=SecureRandom.random_number(37); state['number']=number
        state['bets'].sum { |b| (roulette_multiplier(b['choice'],number)*Amount.parse(b['stake'])).to_i }
      end
    end

    def self.roulette_multiplier(choice,number)
      return choice=="n#{number}" ? 36 : 0 if choice.start_with?('n')
      return %w[red black odd even low high].include?(choice) ? Rational(1,2) : 0 if number.zero?
      case choice
      when 'red' then RED.include?(number) ? 2 : 0
      when 'black' then RED.include?(number) ? 0 : 2
      when 'odd' then number.odd? ? 2 : 0
      when 'even' then number.even? ? 2 : 0
      when 'low' then number<=18 ? 2 : 0
      when 'high' then number>=19 ? 2 : 0
      when /\Adozen([123])\z/ then (number-1)/12+1==$1.to_i ? 3 : 0
      when /\Acolumn([123])\z/ then (number-1)%3+1==$1.to_i ? 3 : 0
      else 0
      end
    end

    def self.shuffle(items)
      items=items.dup
      (items.size-1).downto(1) { |i| j=SecureRandom.random_number(i+1); items[i],items[j]=items[j],items[i] }
      items
    end
    def self.score(cards)
      total=cards.sum { |card| [card%13+1,10].min }; aces=cards.count { |c| c%13==0 }
      total+=10 if aces.positive? && total+10<=21
      total
    end
    def self.view(round)
      state=round.state.slice('choice','bets','result','symbols','multiplier','tiles','dice','total','landed','number','doubled','spots','spot_stake','rules_version')
      if round.game=='blackjack'
        state['player']=round.state.fetch('player')
        state['dealer']=round.status=='settled' ? round.state.fetch('dealer') : [round.state.fetch('dealer').first,nil]
        state['player_score']=score(state['player'])
        state['dealer_score']=score(state['dealer'].compact)
        state['can_double']=round.status=='playing' && state['player'].size==2
      end
      {id:round.id,game:round.game,name:NAMES.fetch(round.game),status:round.status,version:round.version,
       stake:Amount.format(round.stake_units.to_i),payout:Amount.format(round.payout_units.to_i),
       net:round.status=='settled' ? Amount.format(round.payout_units.to_i-round.stake_units.to_i) : nil,
       state:state,created_at:round.created_at,settled_at:round.settled_at}
    end
    def self.state(actor,before:nil,round_id:nil,page:nil)
      ensure_access!(actor)
      selected=GameRound.find_by(id:round_id,user_id:actor.id) if round_id
      raise Discourse::NotFound if round_id && !selected
      wallet=Account.wallet_snapshot(actor.id)
      scope=GameRound.where(user_id:actor.id)
      total=scope.count
      pages=[(total+19)/20,1].max
      # A wallet link opens the page containing its round, even outside recent history.
      page ||= selected ? scope.where('id > ?',selected.id).count/20+1 : 1
      page=page.to_i.clamp(1,pages)
      history=scope.order(id: :desc)
      history=before ? history.where('id < ?',before) : history.offset((page-1)*20)
      rows=history.limit(21).to_a
      {selected_round:selected && view(selected),lottery:Lottery.summary,balance:wallet.balance,wallet_status:wallet.status,read_only:Safety.read_only?,max_stake:SiteSetting.rsc_games_max_stake,min_stake:'0.01',stake_step:'0.01',
       active:GameRound.where(user_id:actor.id,status:'playing').first&.then { |r| view(r) },
       history_page:page,history_pages:pages,history_total:total,history:rows.first(20).map { |r| view(r) },next_cursor:rows.size>20 ? rows[19].id : nil}
    end
  end
end
