# frozen_string_literal: true

class CreateRscAccounting < ActiveRecord::Migration[7.2]
  def up
    create_table :discourse_rsc_accounts do |t|
      t.string :key, null: false, limit: 160
      t.integer :user_id
      t.string :kind, null: false, limit: 24
      t.string :status, null: false, default: "active", limit: 16
      t.decimal :balance_units, precision: 78, scale: 0, null: false, default: 0
      t.timestamps null: false
    end
    add_index :discourse_rsc_accounts, :key, unique: true
    add_index :discourse_rsc_accounts, :user_id
    add_check_constraint :discourse_rsc_accounts, "kind IN ('wallet', 'escrow', 'system')", name: "rsc_account_kind"
    add_check_constraint :discourse_rsc_accounts, "status IN ('active', 'frozen')", name: "rsc_account_status"
    add_check_constraint :discourse_rsc_accounts, "kind = 'system' OR balance_units >= 0", name: "rsc_account_nonnegative"
    add_check_constraint :discourse_rsc_accounts, "kind <> 'wallet' OR user_id IS NOT NULL", name: "rsc_wallet_owner"

    create_table :discourse_rsc_journals do |t|
      t.string :request_key, null: false, limit: 160
      t.string :fingerprint, null: false, limit: 64
      t.string :operation, null: false, limit: 40
      t.integer :actor_user_id
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
      t.bigint :created_xid, null: false, default: -> { "txid_current()" }
    end
    add_index :discourse_rsc_journals, :request_key, unique: true
    add_index :discourse_rsc_journals, [:actor_user_id, :created_at], name: "rsc_journal_actor_time"

    create_table :discourse_rsc_entries do |t|
      t.bigint :journal_id, null: false
      t.bigint :account_id, null: false
      t.decimal :units, precision: 78, scale: 0, null: false
      t.decimal :balance_after_units, precision: 78, scale: 0, null: false
      t.datetime :created_at, null: false
    end
    add_index :discourse_rsc_entries, [:journal_id, :account_id], unique: true, name: "rsc_entry_journal_account"
    add_index :discourse_rsc_entries, [:account_id, :id], name: "rsc_entry_account_cursor"
    add_foreign_key :discourse_rsc_entries, :discourse_rsc_journals, column: :journal_id
    add_foreign_key :discourse_rsc_entries, :discourse_rsc_accounts, column: :account_id
    add_check_constraint :discourse_rsc_entries, "units <> 0", name: "rsc_entry_nonzero"

    create_table :discourse_rsc_events do |t|
      t.bigint :journal_id, null: false
      t.integer :recipient_user_id, null: false
      t.string :kind, null: false, limit: 40
      t.jsonb :payload, null: false, default: {}
      t.bigint :notification_id
      t.datetime :delivered_at
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at, null: false
      t.string :last_error, limit: 120
      t.timestamps null: false
    end
    add_foreign_key :discourse_rsc_events, :discourse_rsc_journals, column: :journal_id
    add_index :discourse_rsc_events, [:journal_id, :recipient_user_id, :kind], unique: true, name: "rsc_event_identity"
    add_index :discourse_rsc_events, :next_attempt_at, where: "delivered_at IS NULL", name: "rsc_event_pending"

    # Enforce conservation even when a writer bypasses the Ruby service.
    execute <<~SQL
      CREATE FUNCTION discourse_rsc_check_journal() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT count(*) FROM discourse_rsc_entries WHERE journal_id = NEW.id) < 2
           OR (SELECT COALESCE(sum(units), 0) FROM discourse_rsc_entries WHERE journal_id = NEW.id) <> 0 THEN
          RAISE EXCEPTION 'RSC journal must have at least two balanced entries';
        END IF;
        RETURN NULL;
      END;
      $$;
      CREATE CONSTRAINT TRIGGER discourse_rsc_balanced_journal
      AFTER INSERT ON discourse_rsc_journals DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION discourse_rsc_check_journal();

      CREATE FUNCTION discourse_rsc_reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'RSC accounting history is immutable; append a reversal instead';
      END;
      $$;
      CREATE TRIGGER discourse_rsc_immutable_journals BEFORE UPDATE OR DELETE ON discourse_rsc_journals
      FOR EACH ROW EXECUTE FUNCTION discourse_rsc_reject_mutation();
      CREATE TRIGGER discourse_rsc_immutable_entries BEFORE UPDATE OR DELETE ON discourse_rsc_entries
      FOR EACH ROW EXECUTE FUNCTION discourse_rsc_reject_mutation();

      CREATE FUNCTION discourse_rsc_check_entry_transaction() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM discourse_rsc_journals WHERE id = NEW.journal_id AND created_xid = txid_current()) THEN
          RAISE EXCEPTION 'Cannot append entries to a committed RSC journal';
        END IF;
        RETURN NEW;
      END;
      $$;
      CREATE TRIGGER discourse_rsc_entry_transaction BEFORE INSERT ON discourse_rsc_entries
      FOR EACH ROW EXECUTE FUNCTION discourse_rsc_check_entry_transaction();
    SQL
  end

  def down
    drop_table :discourse_rsc_events
    drop_table :discourse_rsc_entries
    drop_table :discourse_rsc_journals
    drop_table :discourse_rsc_accounts
    execute "DROP FUNCTION discourse_rsc_check_journal()"
    execute "DROP FUNCTION discourse_rsc_reject_mutation()"
    execute "DROP FUNCTION discourse_rsc_check_entry_transaction()"
  end
end
