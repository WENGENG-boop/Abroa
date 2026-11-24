require "test_helper"

class Abroa::SourceRecordTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = Account.create!(family: @family, owner: @user, accountable: Depository.new,
      name: "Import account", currency: "CNY", balance: 1000)
  end

  test "same file row and external id in another file preserve one canonical record" do
    first = normalized(row_key: "file-a:1", external_id: "order-1")
    second = normalized(row_key: "file-b:8", external_id: "order-1")
    assert_no_difference "Entry.count" do
      record = Abroa::SourceRecord.ingest!(family: @family, record: first, account: @account)
      assert_equal record.id, Abroa::SourceRecord.ingest!(family: @family, record: first, account: @account).id
      assert_equal record.id, Abroa::SourceRecord.ingest!(family: @family, record: second, account: @account).id
      assert_equal 2, record.observations.count
      assert_equal "parsed", record.reload.status
    end
  end

  test "same day and amount with distinct row identity never collapse" do
    first = normalized(row_key: "file-a:1")
    second = normalized(row_key: "file-a:2")
    assert_difference "Abroa::SourceRecord.count", 2 do
      Abroa::SourceRecord.ingest!(family: @family, record: first, account: @account)
      Abroa::SourceRecord.ingest!(family: @family, record: second, account: @account)
    end
  end

  test "changed stable source record retains both observations and requires review" do
    original = normalized(row_key: "file-a:1", external_id: "order-1")
    updated = normalized(row_key: "file-b:1", external_id: "order-1", amount: "101")
    record = Abroa::SourceRecord.ingest!(family: @family, record: original, account: @account)
    replay = Abroa::SourceRecord.ingest!(family: @family, record: updated, account: @account)

    assert_equal record.id, replay.id
    assert_equal "review", replay.status
    assert_equal BigDecimal("100"), replay.amount
    assert_equal 2, replay.observations.count
    assert_equal "conflict", replay.observations.find_by!(source_row_key: "file-b:1").status
  end

  test "reuse of a row identity with different contents is rejected" do
    original = normalized(row_key: "file-a:1", external_id: "order-1")
    record = Abroa::SourceRecord.ingest!(family: @family, record: original, account: @account)
    assert_raises(Abroa::SourceRecord::IdentityConflict) do
      Abroa::SourceRecord.ingest!(family: @family,
        record: normalized(row_key: "file-a:1", external_id: "order-2"), account: @account)
    end
    assert_equal 1, record.observations.count
  end

  test "source identity is tenant isolated and cannot point to another tenant account" do
    row = normalized(row_key: "file-a:1", external_id: "order-1")
    original = Abroa::SourceRecord.ingest!(family: @family, record: row, account: @account)
    outsider = users(:empty)
    other = Abroa::SourceRecord.ingest!(family: outsider.family, record: row)
    assert_not_equal original.id, other.id
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::SourceRecord.ingest!(family: outsider.family, record: row, account: @account)
    end
  end

  test "closed records are ignored and pending evidence cannot write ledger" do
    assert_no_difference "Entry.count" do
      closed = Abroa::SourceRecord.ingest!(family: @family, record: normalized(row_key: "closed:1", provider_status: "closed"))
      pending = Abroa::SourceRecord.ingest!(family: @family, record: normalized(row_key: "pending:1", provider_status: "pending"))
      assert_equal "ignored", closed.status
      assert_equal "parsed", pending.status
      assert_not pending.postable?
    end
  end

  test "invalid amount currency and direction are rejected without source or ledger writes" do
    assert_no_difference [ "Entry.count", "Abroa::SourceRecord.count" ] do
      [ { amount: "NaN" }, { currency: "INVALID" }, { direction: "unknown" }, { local_date: "not-date" } ].each do |overrides|
        assert_raises(ArgumentError) { normalized(row_key: "bad:1", **overrides) }
      end
    end
  end

  test "provider wrapper links the precise existing source id without changing ledger" do
    entry = @account.entries.create!(entryable: Transaction.new, name: "Bank charge", amount: 100,
      currency: "CNY", date: Date.new(2025, 1, 10), external_id: "bank-id-1", source: "simplefin")
    assert_no_difference "Entry.count" do
      record = Abroa::ProviderSource.capture_existing!(entry)
      assert_equal entry.id, record.entry_id
      assert_equal "linked", record.status
      assert_equal record.id, Abroa::ProviderSource.capture_existing!(entry).id
    end
  end

  test "same stable pending order becomes posted without duplicate or conflict" do
    pending = normalized(row_key: "pending:1", external_id: "order-1", provider_status: "pending")
    posted = normalized(row_key: "posted:1", external_id: "order-1", provider_status: "posted")
    record = Abroa::SourceRecord.ingest!(family: @family, record: pending, account: @account)
    assert_not record.postable?
    assert_no_difference [ "Entry.count", "Abroa::SourceRecord.count" ] do
      updated = Abroa::SourceRecord.ingest!(family: @family, record: posted, account: @account)
      assert_equal record.id, updated.id
      assert_equal "parsed", updated.status
      assert_equal "posted", updated.normalized.fetch("provider_status")
      assert updated.postable?
      assert_equal 2, updated.observations.count
      assert_equal "pending", updated.observations.find_by!(source_row_key: "pending:1").normalized.fetch("provider_status")
      assert_equal "observed", updated.observations.find_by!(source_row_key: "posted:1").status

      stale = normalized(row_key: "pending:2", external_id: "order-1", provider_status: "pending")
      assert_equal updated.id, Abroa::SourceRecord.ingest!(family: @family, record: stale, account: @account).id
      assert_equal "posted", updated.reload.normalized.fetch("provider_status")
      assert_equal "parsed", updated.status
      assert_equal 3, updated.observations.count
    end
  end

  test "closing a still-unposted pending order preserves evidence and prevents posting" do
    pending = normalized(row_key: "pending:1", external_id: "order-1", provider_status: "pending")
    closed = normalized(row_key: "closed:1", external_id: "order-1", provider_status: "closed")
    record = Abroa::SourceRecord.ingest!(family: @family, record: pending, account: @account)
    assert_no_difference "Entry.count" do
      assert_equal record.id, Abroa::SourceRecord.ingest!(family: @family, record: closed, account: @account).id
      assert_equal "ignored", record.reload.status
      assert_not record.postable?
      assert_equal "closed", record.normalized.fetch("provider_status")
      assert_equal 2, record.observations.count
    end
  end

  test "changed pending amount is not silently accepted as posted" do
    pending = normalized(row_key: "pending:1", external_id: "order-1", provider_status: "pending")
    posted = normalized(row_key: "posted:1", external_id: "order-1", provider_status: "posted", amount: "110")
    record = Abroa::SourceRecord.ingest!(family: @family, record: pending, account: @account)
    assert_equal record.id, Abroa::SourceRecord.ingest!(family: @family, record: posted, account: @account).id
    assert_equal "review", record.reload.status
    assert_equal BigDecimal("100"), record.amount
    assert_equal "conflict", record.observations.find_by!(source_row_key: "posted:1").status
  end

  test "provider pending flag may clear without writing or duplicating the ledger" do
    entry = @account.entries.create!(entryable: Transaction.new(extra: { "simplefin" => { "pending" => true } }),
      name: "Pending charge", amount: 100, currency: "CNY", date: Date.new(2025, 1, 10),
      external_id: "bank-id-1", source: "simplefin")
    record = Abroa::ProviderSource.capture_existing!(entry)
    assert_equal "parsed", record.status
    assert_nil record.entry_id
    entry.transaction.update!(extra: { "simplefin" => { "pending" => false } })
    assert_no_difference [ "Entry.count", "Abroa::SourceRecord.count" ] do
      updated = Abroa::ProviderSource.capture_existing!(entry.reload)
      assert_equal record.id, updated.id
      assert_equal "linked", updated.status
      assert_equal entry.id, updated.entry_id
      assert_equal 2, updated.observations.count
      assert_equal "Pending charge", entry.reload.name
    end
  end

  private
    def normalized(row_key:, **overrides)
      attributes = {
        source_kind: "bank_statement", source_instance_key: "account-1", source_row_key: row_key,
        raw_digest: Digest::SHA256.hexdigest([ row_key, overrides ].to_json),
        local_date: Date.new(2025, 1, 10), amount: "100", currency: "CNY",
        direction: "outflow", provider_status: "posted", transaction_kind: "payment", description: "Bank charge"
      }.merge(overrides)
      Abroa::NormalizedSource.build(**attributes)
    end
end
