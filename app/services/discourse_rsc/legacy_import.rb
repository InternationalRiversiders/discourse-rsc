# frozen_string_literal: true
module DiscourseRsc
  class LegacyImport
    def self.run(path, apply: false, expected_sha256: nil, identity_review: {})
      raw = File.read(path)
      digest = Digest::SHA256.hexdigest(raw)
      raise Error.new("import_checksum_required") if apply && expected_sha256 != digest
      data = JSON.parse(raw)
      raise Error.new("invalid_import_format") unless data["format"] == "rsc-native-export-v1"
      if data.key?("rehearsal_subset") && !(ENV["RSC_DISPOSABLE_CONTAINER"] == "1" && GlobalSetting.db_name == "rsc_discourse_smoke")
        raise Error.new("import_subset_requires_disposable_database")
      end
      importer = new(data.fetch("tables"), digest, identity_review)
      report = nil
      ActiveRecord::Base.transaction do
        Commands.lock("rsc-import")
        raise Error.new("import_requires_disabled_plugin") if apply && SiteSetting.rsc_enabled
        raise Error.new("import_requires_empty_ledger") if Journal.exists? || Position.exists? || Order.exists? || Prediction.exists? || Packet.exists? || LegacyRecord.exists?
        report = importer.import
        report[:sha256] = digest
        report[:applied] = apply
        # Run deferred accounting constraints even in a rolled-back rehearsal.
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
        raise ActiveRecord::Rollback unless apply
      end
      report
    end

    def initialize(tables, digest, identity_review = {})
      @tables, @digest = tables, digest
      @identity_review = identity_review
      @quarantined = []
      @renamed = []
      @instruments, @matches, @packets = {}, {}, {}
      @totals = Hash.new(0)
      @opening_postings, @opening_sources = {}, []
      @opening_account_ids = {}
      @opening_batch = 0
    end

    def rows(table)
      @tables.fetch(table, [])
    end

    def units(value)
      Amount.parse(value || "0")
    end

    def user(value)
      id = Integer(value)
      exists = @usernames&.key?(id) || User.exists?(id: id)
      raise Error.new("import_missing_user_#{id}") unless exists
      id
    end

    def opening(account, value, key, bucket)
      value = units(value) if value.is_a?(String)
      @totals[bucket] += value
      return if value.zero?
      raise Error.new("import_duplicate_opening_account") if @opening_account_ids[account.id]
      @opening_account_ids[account.id] = true
      @opening_postings[account.id] = value
      @opening_sources << { account_id: account.id, source: key, bucket: bucket }
      flush_openings if @opening_postings.size >= 100
    end

    def flush_openings
      return if @opening_postings.empty?
      @issuance_account_id ||= Account.issuance.id
      @opening_batch += 1
      # Use the normal ledger writer and its database constraints for each batch.
      # Updating the same issuance row thousands of times in one transaction
      # creates a long PostgreSQL tuple chain; batching avoids that cost.
      Commands.move(user_id: nil, action: "legacy_opening", request_id: "import-opening-#{@opening_batch}", settlement: true,
                    postings: @opening_postings.merge(@issuance_account_id => -@opening_postings.values.sum),
                    metadata: { source_sha256: @digest, sources: @opening_sources })
      @opening_postings, @opening_sources = {}, []
    end

    def import
      # Validate identities before copying potentially hundreds of thousands of
      # history rows. Never create forum accounts from legacy identities.
      ids = rows("users").map { |row| Integer(row.fetch("discourse_user_id")) }
      @usernames = User.where(id: ids).pluck(:id, :username).to_h
      raise Error.new('import_identity_review_checksum') if @identity_review.present? && @identity_review['source_sha256'] != @digest
      approved_missing = Array(@identity_review['quarantine_user_ids']).map { |id| Integer(id) }
      raise Error.new('import_invalid_quarantine') unless (approved_missing - (ids - @usernames.keys)).empty?
      rows("users").each do |row|
        if approved_missing.include?(Integer(row.fetch('discourse_user_id')))
          # Only an idle, deleted user's wallet can be held without inventing a
          # forum identity. Orders, positions and social/sports ownership require
          # a separate reviewed resolution; never discard those records.
          id = Integer(row.fetch('discourse_user_id'))
          allowed = %w[users point_accounts daily_activity reward_payouts ledger_entries]
          dependent = @tables.any? do |table, records|
            !allowed.include?(table) && records.any? do |record|
              record.any? { |key, value| key.include?('discourse_user_id') && value.to_s == id.to_s }
            end
          end
          raise Error.new('import_quarantine_has_dependencies') if dependent
          @quarantined << id
          next
        end
        id = user(row.fetch("discourse_user_id"))
        if row["username"].present? && @usernames.fetch(id).downcase != row["username"].downcase
          approval = @identity_review.fetch('renamed_users', {})[id.to_s]
          unless approval == {'previous_username'=>row['username'],'current_username'=>@usernames.fetch(id)}
            raise Error.new("import_user_identity_mismatch_#{id}")
          end
          @renamed << id
        end
      end
      # Archive source rows exactly; history is not replayed against opening balances.
      @tables.each do |table, records|
        raise Error.new("games_excluded") if table.start_with?("game_")
        records.each_slice(500).with_index do |batch, batch_index|
          LegacyRecord.insert_all!(batch.each_with_index.map do |row, index|
            { source_table: table, source_id: (row["id"] || batch_index * 500 + index).to_s, data: row, created_at: Time.current }
          end)
        end
      end
      rows("point_accounts").each do |row|
        id = Integer(row.fetch('discourse_user_id'))
        if @quarantined.include?(id)
          account = Account.internal("legacy-quarantine:#{id}")
          opening(account, row.fetch('balance_rsc'), "quarantine-#{id}", :quarantined_wallet)
          account.update!(status: 'frozen', status_reason: "Deleted legacy user ##{id}; original ownership retained in archive")
          next
        end
        wallet = Account.wallet(user(row.fetch("discourse_user_id")))
        opening(wallet, row.fetch("balance_rsc"), "wallet-#{wallet.user_id}", :wallet)
        wallet.update!(status: row["status"] == "active" ? "active" : "frozen", status_reason: row["ban_reason"])
      end
      rows("market_instruments").each do |row|
        crypto = row["market_category"] == "crypto"
        provider, code = Catalog.provider(row)
        @instruments[row.fetch("id")] = Instrument.create!(symbol: row.fetch("symbol"), name: row.fetch("name"), category: row.fetch("market_category", "us"),
          asset_type: row.fetch("asset_type", ""), currency: row.fetch("currency", "USD"), provider: provider, provider_symbol: code,
          minimum_units: units(row.fetch("min_quantity", "1")), step_units: units(row.fetch("quantity_step", "1")), fee_bps: row.fetch("fee_bps", 10), active: row["is_active"] != 0)
      end
      LegacyMarket.restore!
      rows("positions").each do |row|
        next if units(row["quantity"]).zero?
        raise Error.new("import_invalid_position") unless %w[long short].include?(row.fetch("side", "long")) && row.fetch("leverage", 1).to_i.between?(1, 100) && units(row.fetch("margin_rsc")).positive? && units(row.fetch("average_price_rsc")).positive?
        position = Position.create!(user_id: user(row.fetch("discourse_user_id")), instrument_id: @instruments.fetch(row.fetch("instrument_id")).id,
          side: row.fetch("side", "long"), quantity_units: units(row.fetch("quantity")), average_units: units(row.fetch("average_price_rsc")),
          leverage: row.fetch("leverage", 1), margin_units: units(row.fetch("margin_rsc")),
          take_profit_units: row["take_profit_price_rsc"] && units(row["take_profit_price_rsc"]), stop_loss_units: row["stop_loss_price_rsc"] && units(row["stop_loss_price_rsc"]))
        opening(Account.internal("position:#{position.id}"), position.margin_units.to_i, "position-#{row['id']}", :margin)
      end
      rows("exchange_orders").each do |row|
        # Legacy pending reservations were virtual: wallet balances already include
        # them. Import as canceled, without crediting a second refund.
        close = %w[sell cover close].include?(row["side"])
        Order.create!(user_id: user(row.fetch("discourse_user_id")), instrument_id: @instruments.fetch(row.fetch("instrument_id")).id,
          side: close ? "close" : row.fetch("position_side", row["side"] == "short" ? "short" : "long"), leverage: row.fetch("leverage", 1),
          status: { "pending" => "canceled", "cancelled" => "canceled", "liquidated" => "filled" }.fetch(row["status"], row["status"]), quantity_units: units(row.fetch("quantity")),
          details: { legacy_id: row["id"], legacy_status: row["status"], price: row["executed_price_rsc"], pnl: row.fetch("pnl_rsc", "0"), fee: row.fetch("fee_rsc", "0"), reason: "legacy_import" },
          created_at: row.fetch("created_at"), updated_at: row.fetch("updated_at", row["created_at"]))
      end
      rows("world_cup_matches").each do |row|
        @matches[row.fetch("id")] = SportMatch.create!(external_id: row.fetch("external_id"), sport: row.fetch("sport_key", "soccer"), league: row.fetch("league_slug", "fifa.world"),
          home: row.fetch("home_team"), away: row.fetch("away_team"), starts_at: row.fetch("starts_at"), status: row.fetch("status"), allow_draw: row.fetch("allow_draw", 1) != 0,
          odds: { home: row["odds_home"], draw: row["odds_draw"], away: row["odds_away"] }.compact, odds_at: row["odds_updated_at"],
          score: { home: row["home_score"], away: row["away_score"] }, result: row["result_pick"], confirmed_at: nil, source: row.fetch("source", "espn"),
          provider_data: { stage: row["stage"], home_logo: SportsPresentation.safe_logo(row["home_logo"]), away_logo: SportsPresentation.safe_logo(row["away_logo"]), home_abbr: row["home_abbr"], away_abbr: row["away_abbr"] }.compact)
      end
      rows("world_cup_predictions").each do |row|
        prediction = Prediction.create!(user_id: user(row.fetch("discourse_user_id")), sport_match_id: @matches.fetch(row.fetch("match_id")).id,
          pick: row.fetch("pick"), stake_units: units(row.fetch("stake_rsc")), odds: row.fetch("odds_decimal"), status: row.fetch("status"), payout_units: units(row.fetch("payout_rsc", "0")),
          settled_at: row["settled_at"], created_at: row.fetch("created_at"), revisions: rows("world_cup_prediction_updates").select { |r| r["prediction_id"] == row["id"] })
        opening(Account.internal("prediction:#{prediction.id}"), prediction.stake_units.to_i, "prediction-#{row['id']}", :predictions) if prediction.status == "pending"
      end
      import_packets
      rows("reward_payouts").select { |row| row["status"] == "success" }.each_slice(500) do |batch|
        Command.insert_all!(batch.map do |row|
          original_id = Integer(row.fetch('discourse_user_id'))
          id, date = @quarantined.include?(original_id) ? original_id : user(original_id), row.fetch("date")
          { key: "daily_reward:#{id}:daily-#{date}", fingerprint: Digest::SHA256.hexdigest(JSON.generate([date])), result: { date: date, imported: true }, created_at: Time.current }
        end)
      end
      rows("outgoing_limit_exemptions").each do |row|
        next unless Time.iso8601(row.fetch("expires_at")) > Time.current
        Exemption.create!(user_id: user(row.fetch("discourse_user_id")), starts_at: row["starts_at"], expires_at: row["expires_at"], reason: row["reason"].presence || "Legacy exemption", actor_user_id: row["created_by_discourse_user_id"] || Discourse::SYSTEM_USER_ID)
      end
      LegacyRules.restore!(during_import: true)
      flush_openings
      expected = @totals.values.sum
      actual = Account.where(kind: %w[wallet escrow]).sum(:balance_units).to_i
      raise Error.new("import_reconciliation_failed") unless expected == actual && Entry.sum(:units).zero?
      { rows: @tables.transform_values(&:size), totals: @totals.transform_values { |value| Amount.format(value) }, opening_assets: Amount.format(actual),
        canceled_pending_orders: rows("exchange_orders").count { |row| row["status"] == "pending" },
        quarantined_user_ids: @quarantined, renamed_user_ids: @renamed, balanced: true }
    end

    def import_packets
      rows("rsc_red_packets").each do |row|
        claims = rows("rsc_red_packet_claims").select { |claim| claim["packet_id"] == row["id"] }.sort_by { |claim| claim["id"] }
        allocations = rows("rsc_red_packet_allocations").select { |a| a["packet_id"] == row["id"] && a["claim_id"].nil? }.sort_by { |a| a["sequence"] }.map { |a| units(a["amount_rsc"]) }
        state = { "active" => "open", "depleted" => "exhausted" }.fetch(row["status"], row["status"])
        remaining = units(row.fetch("remaining_rsc"))
        raise Error.new("import_invalid_packet_status") unless %w[open closed expired exhausted].include?(state)
        raise Error.new("import_closed_packet_has_funds") if state != "open" && remaining.positive?
        if state == "open"
          if allocations.empty? && row["amount_mode"] == "fixed"
            allocations = Array.new(row.fetch("max_claims") - claims.size, units(row.fetch("amount_rsc")))
          end
          raise Error.new("import_packet_allocations_mismatch") unless allocations.sum == remaining && claims.sum { |claim| units(claim.fetch("amount_rsc")) } + remaining == units(row.fetch("total_rsc"))
        end
        values = claims.map { |claim| units(claim["amount_rsc"]) } + allocations
        packet = Packet.create!(user_id: user(row.fetch("creator_discourse_user_id")), token: row.fetch("public_token"), mode: row.fetch("amount_mode"),
          message: row["message"] || "", claim_limit: row["max_claims"], minimum_units: units(row["min_amount_rsc"] || row["amount_rsc"] || "0"), maximum_units: units(row["max_amount_rsc"] || row["amount_rsc"] || "0"), status: state, total_units: units(row.fetch("total_rsc")), allocations: values.map(&:to_s), expires_at: row["expires_at"] || Time.current, created_at: row.fetch("created_at"))
        claims.each { |claim| packet.claims.create!(user_id: user(claim.fetch("recipient_discourse_user_id")), units: units(claim.fetch("amount_rsc")), created_at: claim.fetch("created_at")) }
        opening(Account.internal("packet:#{packet.id}"), remaining, "packet-#{row['id']}", :packets) if state == "open"
      end
    end
  end
end
