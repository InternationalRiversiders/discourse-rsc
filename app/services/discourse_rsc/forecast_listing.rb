# frozen_string_literal: true
module DiscourseRsc
  module ForecastListing
    def self.replay(actor:, action:, request_id:, input:)
      return unless Command.exists?(key: "#{action}:#{actor.id}:#{request_id}")
      Commands.run(user_id:actor.id,action:action,request_id:request_id,input:input) { raise 'Missing saved command' }
    end

    def self.submit(actor:, external_id:, reason:, request_id:)
      Access.ensure_member!(actor)
      Safety.ensure_writable!
      external_id = ForecastCatalog.id(external_id)
      raise Error.new('reason_required') unless reason.is_a?(String) && reason.strip.length.between?(1, 500)
      previous = replay(actor:actor,action:'forecast_request',request_id:request_id,input:[external_id,reason.strip])
      return previous if previous
      raw = ForecastCatalog.raw(external_id)
      Commands.run(user_id: actor.id, action: 'forecast_request', request_id: request_id, input: [external_id,reason.strip]) do
        Commands.lock("forecast-listing:#{external_id}")
        market = ForecastMarket.find_by(external_id: external_id)
        next({status:'approved',market_id:market.id}) if market
        Commands.lock("forecast-requests-user:#{actor.id}")
        row = ForecastRequest.find_or_initialize_by(user_id: actor.id, external_id: external_id)
        next({status:row.status,id:row.id}) if row.persisted? && row.status=='pending'
        raise Error.new('forecast_request_recent') if row.persisted? && row.updated_at > 1.day.ago
        raise Error.new('forecast_request_limit') if ForecastRequest.where(user_id:actor.id,status:'pending').count >= 5
        row.assign_attributes(question:raw['question'],terms_digest:ForecastProvider.parse(raw)[:terms_digest],reason:reason.strip,status:'pending',review_reason:'',reviewer_id:nil)
        row.save!
        {id:row.id,status:row.status}
      end
    end

    def self.review(actor:, external_id:, decision:, reason:, request_id:)
      raise Error.new('admin_required',status:403) unless Access.admin?(actor)
      Safety.ensure_writable!
      external_id = ForecastCatalog.id(external_id)
      raise Error.new('invalid_section') unless %w[approved rejected].include?(decision)
      reason = reason.to_s.strip
      raise Error.new('reason_required') if reason.length > 500 || (decision=='rejected' && reason.empty?)
      previous = replay(actor:actor,action:'forecast_request_review',request_id:request_id,input:[external_id,decision,reason])
      return previous if previous
      raise Error.new('forecast_request_missing') unless ForecastRequest.exists?(external_id:external_id,status:'pending')
      # Check live contract and both order books before taking the transaction lock.
      raw = ForecastCatalog.raw(external_id) if decision=='approved'
      attrs = ForecastProvider.parse(raw) if raw
      if attrs
        if ForecastRequest.where(external_id:external_id,status:'pending').where.not(terms_digest:attrs[:terms_digest]).exists?
          raise Error.new('forecast_request_changed')
        end
        raise Error.new('forecast_not_eligible') unless attrs[:ends_at] > 1.hour.from_now
        candidate = ForecastMarket.new(attrs)
        row = ForecastProvider.resolution(candidate)
        if row && (row['extended_review']==true || !%w[posed unresolved open].include?(row['status']))
          raise Error.new('forecast_closed')
        end
        2.times { |outcome| ForecastExchange.fill(ForecastProvider.book(candidate,outcome),'buy',ForecastExchange::UNIT) }
      end
      Commands.run(user_id:actor.id,action:'forecast_request_review',request_id:request_id,input:[external_id,decision,reason]) do
        Commands.lock("forecast-listing:#{external_id}")
        requests=ForecastRequest.where(external_id:external_id,status:'pending').order(:id).lock.to_a
        next({reviewed:0}) if requests.empty?
        raise Error.new('forecast_request_changed') if attrs && requests.any? { |request| request.terms_digest != attrs[:terms_digest] }
        market=ForecastProvider.ingest(raw,featured: ForecastMarket.exists?(external_id:external_id) ? nil : false) if raw
        raise Error.new('forecast_closed') if market && market.state!='open'
        requests.each do |request|
          request.update!(status:decision,reviewer_id:actor.id,market_id:market&.id,review_reason:reason)
          if SiteSetting.rsc_notifications_enabled
            recipient=User.find(request.user_id)
            text=I18n.t("discourse_rsc.notifications.forecast_request_#{decision}",locale:recipient.effective_locale,question:request.question)
            path=market ? "/rsc/forecast?market_id=#{market.id}" : '/rsc/forecast?section=requests'
            Notification.create!(user_id:recipient.id,notification_type:Notification.types[:custom],data:{river_app:'rsc',river_text:text,river_path:path,river_icon:'chart-line',topic_title:text}.to_json)
          end
        end
        Audit.create!(actor_user_id:actor.id,action:'forecast_request_review',details:{external_id:external_id,decision:decision,reason:reason,request_ids:requests.map(&:id),market_id:market&.id},created_at:Time.current)
        {reviewed:requests.size,market_id:market&.id,status:decision}
      end
    end
  end
end
