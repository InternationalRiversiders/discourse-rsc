# frozen_string_literal: true

# Runs the real migration and services against an expendable PostgreSQL DB.
# Does not boot Discourse or read its database configuration.
require "active_record"
require "minitest/autorun"
require "securerandom"

abort "Only the isolated test database is allowed" unless ENV["RSC_TEST_DATABASE"] == "rsc_native_test"
ActiveRecord::Base.establish_connection(adapter: "postgresql", host: "127.0.0.1", port: 5432,
                                       database: "rsc_native_test", username: "rsc_test",
                                       password: "rsc_test_only", pool: 12, prepared_statements: false)
ActiveRecord.raise_int_wider_than_64bit = true
ROOT = File.expand_path("..", __dir__)
%w[lib/discourse_rsc/error lib/discourse_rsc/amount
   app/models/discourse_rsc/account app/models/discourse_rsc/journal
   app/models/discourse_rsc/entry app/models/discourse_rsc/event
   app/services/discourse_rsc/ledger].each { |file| require "#{ROOT}/#{file}" }
require "#{ROOT}/db/migrate/20260920000000_create_rsc_accounting"
ActiveRecord::Migration.verbose = false
CreateRscAccounting.new.migrate(:down) if ActiveRecord::Base.connection.table_exists?(:discourse_rsc_accounts)
CreateRscAccounting.new.migrate(:up)

class AccountingTest < Minitest::Test
  include DiscourseRsc

  def setup
    ActiveRecord::Base.connection.execute("TRUNCATE discourse_rsc_events, discourse_rsc_entries, discourse_rsc_journals, discourse_rsc_accounts RESTART IDENTITY CASCADE")
    @alice = Account.wallet(1)
    @bob = Account.wallet(2)
    @issuer = Account.issuance
  end

  def post(postings, id: SecureRandom.uuid, operation: "transfer", metadata: {}, events: [], &block)
    Ledger.post(operation: operation, actor_user_id: 1, request_id: id,
                postings: postings, metadata: metadata, events: events, &block)
  end

  def fund(account = @alice, amount = "100")
    units = Amount.positive(amount)
    post({ @issuer.id => -units, account.id => units }, operation: "issuance")
  end

  def test_amount_preserves_eighteen_decimal_places
    assert_equal 1, Amount.positive("0.000000000000000001")
    assert_equal "12345678901234567890.123456789012345678", Amount.format(Amount.parse("12345678901234567890.123456789012345678"))
    assert_equal "-0.000000000000000001", Amount.format(-1)
    assert_equal "10.1", Amount.format(Amount.parse("10.100"))
  end

  def test_amount_rejects_ambiguous_or_imprecise_input
    [1, 1.0, nil, "", "01", "-1", "+1", "1e3", " 1", "1.", ".1", "NaN", "1.0000000000000000001", "9" * 61].each do |input|
      assert_raises(Error, "input=#{input.inspect}") { Amount.parse(input) }
    end
    assert_raises(Error) { Amount.positive("0") }
    assert_raises(Error) { Amount.positive("1.001", decimals: 2) }
    assert_raises(Error) { Amount.format(1.5) }
  end

  def test_transfer_preserves_supply_and_records_snapshots
    fund
    units = Amount.parse("2.50")
    result = post({ @alice.id => -units, @bob.id => units })
    refute result.replayed
    assert_equal "97.5", @alice.reload.balance
    assert_equal "2.5", @bob.reload.balance
    assert_equal 0, Account.sum(:balance_units)
    assert_equal 0, result.journal.entries.sum(:units)
    assert_equal @bob.balance_units, result.journal.entries.find_by!(account_id: @bob.id).balance_after_units
  end

  def test_replay_does_not_repeat_money_or_events
    fund
    units = Amount.parse("1")
    args = { id: "same-request", events: [{ recipient_user_id: 2, kind: "transfer", payload: { "amount" => "1" } }] }
    first = post({ @alice.id => -units, @bob.id => units }, **args)
    second = post({ @alice.id => -units, @bob.id => units }, **args)
    assert second.replayed
    assert_equal first.journal.id, second.journal.id
    assert_equal "1", @bob.reload.balance
    assert_equal 1, Event.count
  end

  def test_changed_amount_or_metadata_cannot_reuse_request_id
    fund
    post({ @alice.id => -1, @bob.id => 1 }, id: "same-request", metadata: { "purpose" => "first" })
    error = assert_raises(Error) { post({ @alice.id => -2, @bob.id => 2 }, id: "same-request", metadata: { "purpose" => "first" }) }
    assert_equal "idempotency_conflict", error.code
    assert_raises(Error) { post({ @alice.id => -1, @bob.id => 1 }, id: "same-request", metadata: { "purpose" => "changed" }) }
  end

  def test_semantically_identical_hash_order_is_a_replay
    fund
    post({ @alice.id => -1, @bob.id => 1 }, id: "same-request", metadata: { "a" => 1, "b" => 2 })
    assert post({ @bob.id => 1, @alice.id => -1 }, id: "same-request", metadata: { "b" => 2, "a" => 1 }).replayed
  end

  def test_failed_transfer_leaves_no_money_journal_or_event
    error = assert_raises(Error) do
      post({ @alice.id => -1, @bob.id => 1 }, events: [{ recipient_user_id: 2, kind: "transfer", payload: {} }])
    end
    assert_equal "insufficient_balance", error.code
    assert_equal 0, Journal.count
    assert_equal 0, Event.count
    assert_equal 0, Entry.count
    assert_equal "0", @bob.reload.balance
  end

  def test_error_after_postings_rolls_back_balances_and_journal
    fund
    assert_raises(KeyError) do
      post({ @alice.id => -1, @bob.id => 1 }, events: [{ kind: "missing_recipient" }])
    end
    assert_equal "100", @alice.reload.balance
    assert_equal "0", @bob.reload.balance
    assert_equal 1, Journal.count
  end

  def test_business_validation_is_inside_transaction
    fund
    assert_raises(Error) do
      post({ @alice.id => -1, @bob.id => 1 }) { raise Error.new("daily_limit") }
    end
    assert_equal "100", @alice.reload.balance
    assert_equal 1, Journal.count
  end

  def test_frozen_accounts_cannot_send_or_receive
    fund
    @bob.update!(status: "frozen")
    assert_raises(Error) { post({ @alice.id => -1, @bob.id => 1 }) }
    @bob.update!(status: "active")
    @alice.update!(status: "frozen")
    assert_raises(Error) { post({ @alice.id => -1, @bob.id => 1 }) }
  end

  def test_replay_after_freeze_returns_original_result
    fund
    post({ @alice.id => -1, @bob.id => 1 }, id: "same-request")
    @alice.update!(status: "frozen")
    assert post({ @alice.id => -1, @bob.id => 1 }, id: "same-request").replayed
  end

  def test_concurrent_transfers_cannot_overspend
    fund(@alice, "1")
    successes = Queue.new
    errors = Queue.new
    threads = 8.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          begin
            post({ @alice.id => -Amount.parse("0.25"), @bob.id => Amount.parse("0.25") })
            successes << true
          rescue Error => error
            errors << error.code
          end
        end
      end
    end
    threads.each(&:value)
    assert_equal 4, successes.size
    assert_equal 4, errors.size
    assert_equal "0", @alice.reload.balance
    assert_equal "1", @bob.reload.balance
  end

  def test_concurrent_identical_requests_post_once
    fund
    results = Queue.new
    8.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results << post({ @alice.id => -1, @bob.id => 1 }, id: "same-request").replayed
        end
      end
    end.each(&:value)
    flags = 8.times.map { results.pop }
    assert_equal 1, flags.count(false)
    assert_equal 7, flags.count(true)
    assert_equal 2, Journal.count
  end

  def test_opposing_transfers_use_consistent_lock_order
    fund(@alice)
    fund(@bob)
    8.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          from, to = index.even? ? [@alice, @bob] : [@bob, @alice]
          post({ from.id => -1, to.id => 1 })
        end
      end
    end.each(&:value)
    assert_equal "100", @alice.reload.balance
    assert_equal "100", @bob.reload.balance
  end

  def test_database_rejects_unbalanced_journal_even_without_service
    assert_raises(ActiveRecord::StatementInvalid) do
      Journal.transaction do
        journal = Journal.create!(request_key: "bad", fingerprint: "bad", operation: "bad", created_at: Time.current)
        Entry.create!(journal_id: journal.id, account_id: @alice.id, units: 1, balance_after_units: 1, created_at: Time.current)
      end
    end
    assert_equal 0, Journal.count
  end

  def test_database_protects_accounting_history
    fund
    assert_raises(ActiveRecord::StatementInvalid) { Entry.first.update!(units: 20) }
    assert_raises(ActiveRecord::StatementInvalid) { Entry.first.delete }
    assert_raises(ActiveRecord::StatementInvalid) { Journal.first.update!(metadata: { altered: true }) }
    assert_raises(ActiveRecord::StatementInvalid) do
      Entry.create!(journal_id: Journal.first.id, account_id: @bob.id, units: 1, balance_after_units: 1, created_at: Time.current)
    end
  end

  def test_invalid_posting_vectors_are_rejected
    [{ @alice.id => 1 }, { @alice.id => -1, @bob.id => 2 }, { @alice.id => 0, @bob.id => 0 },
     { @alice.id => -1.0, @bob.id => 1.0 }].each do |postings|
      assert_raises(Error) { post(postings) }
    end
  end
end
