# frozen_string_literal: true
module DiscourseRsc
  class AdminReports
    # Query both eras in PostgreSQL before paginating: old failures and the
    # original transfer/tip rows remain visible without replaying their ledger.
    def self.activity(kind: "all", query: "", status: "all", topic_id: nil, page: 1)
      raise Error.new("invalid_section") unless %w[all transfer post_tip red_packet issuance admin_adjustment].include?(kind)
      sql = <<~SQL
        SELECT id, 'native' AS origin, operation AS kind, 'success' AS status,
          actor_user_id AS from_id, (metadata->>'recipient_user_id')::bigint AS to_id,
          metadata->>'amount' AS amount, created_at,
          (metadata->>'topic_id')::bigint AS topic_id,
          (metadata->>'post_id')::bigint AS post_id,
          metadata->>'reason' AS detail, NULL::text AS token
        FROM discourse_rsc_journals WHERE operation IN ('transfer','post_tip','issuance','admin_adjustment')
        UNION ALL
        SELECT id, 'legacy', CASE source_table WHEN 'transfers' THEN 'transfer' ELSE 'post_tip' END,
          COALESCE(data->>'status','success'), (data->>'from_discourse_user_id')::bigint,
          (data->>'to_discourse_user_id')::bigint, data->>'amount_rsc',
          (data->>'created_at')::timestamptz, (data->>'topic_id')::bigint,
          (data->>'post_id')::bigint, data->>'error', NULL::text
        FROM discourse_rsc_legacy_records WHERE source_table IN ('transfers','post_tips')
        UNION ALL
        SELECT id, 'legacy', 'issuance', COALESCE(data->>'status','success'),
          (data->>'issued_by_discourse_user_id')::bigint, (data->>'discourse_user_id')::bigint,
          data->>'amount_rsc', (data->>'created_at')::timestamptz,
          NULL::bigint, NULL::bigint, COALESCE(NULLIF(data->>'error',''),data->>'reason'), NULL::text
        FROM discourse_rsc_legacy_records WHERE source_table='coin_issuances'
        UNION ALL
        SELECT id, 'legacy', 'admin_adjustment', 'success',
          (data->>'changed_by_discourse_user_id')::bigint, (data->>'discourse_user_id')::bigint,
          ((data->>'balance_after_rsc')::numeric - (data->>'balance_before_rsc')::numeric)::text,
          (data->>'created_at')::timestamptz, NULL::bigint, NULL::bigint, data->>'reason', NULL::text
        FROM discourse_rsc_legacy_records WHERE source_table='point_account_asset_reset_events'
        UNION ALL
        SELECT id, 'packet', 'red_packet',
          CASE WHEN status='open' AND expires_at<=CURRENT_TIMESTAMP THEN 'expired' ELSE status END,
          user_id, NULL::bigint, (total_units / 1000000000000000000.0)::text, created_at,
          NULL::bigint, NULL::bigint, message, token
        FROM discourse_rsc_packets
      SQL
      scope = Journal.unscoped.from("(#{sql}) AS discourse_rsc_journals")
      scope = scope.where(kind: kind) unless kind == "all"
      scope = scope.where(status: status) unless status == "all"
      if topic_id.present?
        raise Error.new("invalid_admin_input") unless /\A[1-9][0-9]{0,18}\z/.match?(topic_id.to_s)
        scope = scope.where(topic_id: topic_id.to_i)
      end
      q = query.to_s.strip.first(80)
      if q.present?
        ids = User.where("username_lower LIKE ?", "%#{User.sanitize_sql_like(q.downcase)}%").select(:id)
        ids = ids.or(User.where(id: q.to_i)) if /\A[1-9][0-9]{0,18}\z/.match?(q)
        scope = scope.where("from_id IN (:ids) OR to_id IN (:ids)", ids: ids)
      end
      result = Reports.relation_page(scope.order(created_at: :desc, origin: :desc, id: :desc), page: page, per_page: 20) { |row| row.attributes }
      users = User.where(id: result[:rows].flat_map { |r| [r['from_id'], r['to_id']] }).index_by(&:id)
      names = users.transform_values(&:username)
      result[:rows].each do |row|
        row['sender_user'] = UserIdentity.serialize(users[row['from_id']])
        row['recipient_user'] = UserIdentity.serialize(users[row['to_id']])
        row['sender'] = names[row['from_id']] || "##{row['from_id']}"
        row['recipient'] = names[row['to_id']] || (row['to_id'] && "##{row['to_id']}")
        if row['origin'] == 'packet'
          packet = Packet.includes(:claims).find(row['id'])
          row['packet'] = Views.packet(packet, nil)
          row['claims'] = packet.claims.map { |c| { user_id: c.user_id, amount: Amount.format(c.units), at: c.created_at } }
        end
      end
      result
    end

    def self.search_demand(page: 1)
      sql = <<~SQL
        SELECT LOWER(query) AS query, COUNT(*)::bigint AS count, MAX(created_at) AS last_at,
          COUNT(DISTINCT user_id)::bigint AS users, SUM(CASE WHEN result_count=0 THEN 1 ELSE 0 END)::bigint AS empty_results
        FROM (
          SELECT data->>'query' AS query, (data->>'discourse_user_id')::bigint AS user_id,
            COALESCE((data->>'result_count')::integer,0) AS result_count, (data->>'created_at')::timestamptz AS created_at
          FROM discourse_rsc_legacy_records WHERE source_table='market_search_requests'
          UNION ALL
          SELECT query, user_id, result_count, created_at FROM discourse_rsc_searches
        ) searches WHERE query IS NOT NULL GROUP BY LOWER(query)
      SQL
      scope = Journal.unscoped.from("(#{sql}) AS discourse_rsc_journals")
      Reports.relation_page(scope.order(Arel.sql('empty_results DESC, count DESC, last_at DESC, query ASC')), page: page, per_page: 20) { |r| r.attributes }
    end
  end
end
