require "test_helper"

class Abroa::SourceReviewTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Review account", currency: "CNY", balance: 1000)
    @source = source("one")
  end

  test "confirmed creation posts one entry and the same request replays" do
    review = Abroa::SourceReview.open_for!(@user, @source.id)
    assert_equal "pending", review.status
    action = nil
    assert_difference "Entry.count", 1 do
      action = resolve(review, "create", key: "create-one")
    end
    assert_equal "posted", @source.reload.status
    assert_equal BigDecimal("100"), action.entry.amount
    assert_equal "standard", action.entry.transaction.kind
    assert_no_difference "Entry.count" do
      assert_equal action.id, resolve(review, "create", key: "create-one", version: 0).id
    end
    assert_raises(Abroa::SourceReview::Conflict) do
      resolve(review, "ignore", key: "create-one", version: 0)
    end
  end

  test "manual link preserves bank ledger and user category" do
    entry = @account.entries.create!(entryable: Transaction.new, name: "Existing bank entry",
      date: @source.local_date, currency: "CNY", amount: 100, user_modified: true)
    review = Abroa::SourceReview.open_for!(@user, @source.id)
    assert_no_difference "Entry.count" do
      action = resolve(review, "link", key: "link-one", target_entry_id: entry.id)
      assert_equal entry.id, action.entry_id
    end
    assert_equal "Existing bank entry", entry.reload.name
    assert_equal "linked", @source.reload.status
    assert_no_difference "Entry.count" do
      Abroa::SourceReview.reverse_for!(@user, action_id: Abroa::SourceAction.find_by!(source_record: @source).id)
    end
    assert_nil @source.reload.entry_id
    assert_equal "reversed", @source.status
  end

  test "reversal removes only an unchanged entry created by this action" do
    action = resolve(Abroa::SourceReview.open_for!(@user, @source.id), "create", key: "create-one")
    assert_difference "Entry.count", -1 do
      Abroa::SourceReview.reverse_for!(@user, action_id: action.id)
    end
    assert_equal "reversed", @source.reload.status
    assert action.reload.reversed_at.present?
  end

  test "later entry edit or a second source blocks destructive reversal" do
    action = resolve(Abroa::SourceReview.open_for!(@user, @source.id), "create", key: "create-one")
    action.entry.update!(name: "User edit")
    assert_no_difference "Entry.count" do
      assert_raises(Abroa::SourceReview::Conflict) { Abroa::SourceReview.reverse_for!(@user, action_id: action.id) }
    end
  end

  test "foreign user cannot open or resolve a review" do
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::SourceReview.open_for!(users(:empty), @source.id) }
    review = Abroa::SourceReview.open_for!(@user, @source.id)
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::SourceReview.resolve_for!(users(:empty), review_id: review.id, resolution: "create", expected_version: 0, key: "foreign")
    end
  end

  test "version conflict and pending evidence cannot post" do
    review = Abroa::SourceReview.open_for!(@user, @source.id)
    assert_raises(Abroa::SourceReview::Conflict) { resolve(review, "create", key: "stale", version: 99) }
    pending = source("pending", provider_status: "pending")
    assert_no_difference "Entry.count" do
      assert_raises(ArgumentError) { resolve(Abroa::SourceReview.open_for!(@user, pending.id), "create", key: "pending") }
    end
  end

  private
    def source(key, provider_status: "posted")
      row = Abroa::NormalizedSource.build(source_kind: "generic_csv", source_instance_key: "checking",
        source_row_key: key, raw_digest: Digest::SHA256.hexdigest(key), local_date: Date.new(2025, 1, 10),
        amount: "100", currency: "CNY", direction: "outflow", provider_status: provider_status,
        transaction_kind: "payment", description: "Imported charge")
      Abroa::SourceRecord.ingest!(family: @user.family, account: @account, record: row)
    end

    def resolve(review, resolution, key:, version: review.lock_version, **fields)
      Abroa::SourceReview.resolve_for!(@user, review_id: review.id, resolution: resolution,
        expected_version: version, key: key, **fields)
    end
end
