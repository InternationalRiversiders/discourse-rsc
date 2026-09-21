# frozen_string_literal: true
require "base64"
module DiscourseRsc
  class WalletHistory
    def self.page(user, category: "all", cursor: nil)
      raise Error.new("invalid_section") unless %w[all payout activity].include?(category)
      wallet=Account.wallet_snapshot(user.id)
      native=Entry.where(account_id:wallet.id).joins(:journal).includes(:journal).where.not(discourse_rsc_journals:{operation:"legacy_opening"})
      legacy=LegacyRecord.where(source_table:"ledger_entries").where("data ->> 'discourse_user_id' = ?",user.id.to_s)
      if category != "all"
        native = category == "payout" ? native.where(discourse_rsc_journals:{operation:"daily_reward"}) : native.where.not(discourse_rsc_journals:{operation:"daily_reward"})
        legacy=legacy.where("data ->> 'type' #{category == 'payout' ? '=' : '!='} 'reward_payout'")
      end
      if cursor.present?
        at,origin,id=JSON.parse(Base64.urlsafe_decode64(cursor))
        raise Error.new("invalid_page") unless [0,1].include?(origin) && id.is_a?(Integer) && id.positive? && at.is_a?(String)
        at=Time.iso8601(at)
        native=native.where("(discourse_rsc_entries.created_at,1,discourse_rsc_entries.id) < (?,?,?)",at,origin,id)
        legacy=legacy.where("((data ->> 'created_at')::timestamptz,0,id) < (?,?,?)",at,origin,id)
      end
      candidates=native.order("discourse_rsc_entries.created_at DESC, discourse_rsc_entries.id DESC").limit(51).map { |r| [r.created_at,1,r.id,r] }
      candidates+=legacy.order(Arel.sql("(data ->> 'created_at')::timestamptz DESC, id DESC")).limit(51).map { |r| [Time.iso8601(r.data.fetch('created_at')),0,r.id,r] }
      candidates.sort_by! { |at,origin,id,_| [at,origin,id] };candidates.reverse!
      selected=candidates.first(50)
      next_cursor=candidates.size>50 && Base64.urlsafe_encode64(JSON.generate([selected.last[0].iso8601(6),selected.last[1],selected.last[2]]),padding:false)
      {entries:selected.map { |_,origin,_,record| origin==1 ? native_entry(record,user) : legacy_entry(record,user) },next_cursor:next_cursor || nil}
    rescue JSON::ParserError,ArgumentError,TypeError
      raise Error.new("invalid_page")
    end

    def self.native_entry(entry,user)
      journal=entry.journal;data=journal.metadata
      counterparty=if %w[transfer post_tip].include?(journal.operation)
        entry.units.negative? ? data['recipient_user_id'] : journal.actor_user_id
      elsif journal.operation=='red_packet_claim'
        data['sender_user_id']
      elsif journal.actor_user_id && journal.actor_user_id!=user.id
        journal.actor_user_id
      end
      info=context(data,user)
      {id:"native-#{entry.id}",journal_id:journal.id,anchor:"rsc-entry-#{journal.id}",source:"native",operation:journal.operation,amount:Amount.format(entry.units),direction:entry.units.negative? ? 'debit' : 'credit',balance_after:Amount.format(entry.balance_after_units),created_at:entry.created_at,counterparty:identity(counterparty),**info}
    end

    def self.legacy_entry(record,user)
      row=record.data;data=row['metadata']
      data=(JSON.parse(data) rescue {}) if data.is_a?(String)
      data={} unless data.is_a?(Hash)
      info=context(data,user,legacy:true)
      amount=row.fetch('amount_rsc')
      {id:"legacy-#{record.id}",anchor:"rsc-history-#{record.id}",source:"legacy",operation:row['type'],amount:row['direction']=='debit' ? "-#{amount}" : amount,direction:row['direction'],balance_after:row['balance_after'],created_at:row['created_at'],counterparty:identity(row['counterparty_discourse_user_id'],row['counterparty_username']),reference_type:row['reference_type'],reference_id:row['reference_id'],**info}
    end

    def self.identity(id,fallback=nil)
      username=User.find_by(id:id)&.username if id
      return nil unless id || fallback.present?
      {user_id:id,username:username || fallback || "##{id}",url:username && "/u/#{ERB::Util.url_encode(username)}"}
    end

    def self.context(data,user,legacy:false)
      # Only public context fields. Never expose raw imported metadata wholesale.
      detail=data.values_at('reason','date','message','symbol','matchName','homeTeam','awayTeam').select { |v| v.is_a?(String) }.map { |s| s.first(500) }.join(' · ')
      path=nil
      post_id=data['post_id'] || data['postId']
      post=Post.find_by(id:post_id) if post_id
      if post && !post.deleted_at && !post.hidden && Guardian.new(user).can_see?(post)
        path="/t/#{post.topic_id}/#{post.post_number}"
      elsif (topic_id=data['topic_id'] || data['topicId']) && (number=data['post_number'] || data['postNumber'])
        post=Post.find_by(topic_id:topic_id,post_number:number)
        path="/t/#{post.topic_id}/#{post.post_number}" if post && !post.deleted_at && !post.hidden && Guardian.new(user).can_see?(post)
      end
      token=data['packet_token'] || data['token'];packet=Packet.find_by(id:data['packet_id']) if !legacy && data['packet_id'];token||=packet&.token
      path="/rsc/packets/#{token}" if token.is_a?(String) && /\A[A-Za-z0-9_-]{8,100}\z/.match?(token)
      if !legacy && data['order_id']
        order=Order.includes(:instrument).find_by(id:data['order_id']);if order
          path="/rsc/market?instrument_id=#{order.instrument_id}&order_id=#{order.id}#rsc-order-#{order.id}";detail=[order.instrument.symbol,detail].reject(&:blank?).join(' · ')
        end
      end
      if !legacy && (data['match_id'] || data['prediction_id'])
        match=SportMatch.find_by(id:data['match_id']) || Prediction.find_by(id:data['prediction_id'])&.sport_match
        if match;path="/rsc/sports?match_id=#{match.id}#rsc-match-#{match.id}";detail=["#{match.home} — #{match.away}",detail].reject(&:blank?).join(' · ');end
      end
      {detail:detail,path:path}
    end
  end
end
