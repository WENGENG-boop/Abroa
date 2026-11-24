require "test_helper"

class Abroa::ProviderCaptureTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Capture account", currency: "GBP", balance: 100)
  end

  test "capture scans existing provider-identified ledger rows without modifying the ledger" do
    first = external_entry("one")
    second = external_entry("two")
    @account.entries.create!(entryable: Transaction.new, name: "Manual", amount: 10, currency: "GBP", date: Date.current)
    assert_no_difference "Entry.count" do
      result = Abroa::ProviderCapture.capture_for!(@user, account_id: @account.id, limit: 1)
      assert_equal 1, result[:captured_count]
      assert result[:next_cursor].present?
      last = Abroa::ProviderCapture.capture_for!(@user, account_id: @account.id, limit: 1, after_id: result[:next_cursor])
      assert_equal 1, last[:captured_count]
      assert_nil last[:next_cursor]
      assert_equal [ first.id, second.id ].sort, Abroa::SourceRecord.where(account: @account).pluck(:entry_id).sort
      assert_no_difference "Abroa::SourceRecord.count" do
        Abroa::ProviderCapture.capture_for!(@user, account_id: @account.id)
      end
    end
  end

  test "foreign user cannot capture or read diagnostics" do
    other = users(:empty)
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::ProviderCapture.capture_for!(other, account_id: @account.id) }
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::ProviderCapture.diagnostics_for!(other, account_id: @account.id) }
  end

  test "diagnostics expose only status and allowlisted error reason" do
    @account.syncs.create!(status: "failed", error: "HTTP 401 token super-secret-value")
    result = Abroa::ProviderCapture.diagnostics_for!(@user, account_id: @account.id)
    assert_equal "failed", result.dig(:ledger_sync, :status)
    assert_equal "failed", result.dig(:ledger_sync, :error_code)
    refute_includes result.to_json, "super-secret-value"
    assert_equal "unverified", result.fetch(:live_connection_status)
  end

  test "Wise source captures actual provider payment reference rather than editable notes" do
    entry = @account.entries.create!(entryable: Transaction.new(extra: { "wise" => {
      "statement_id" => "123", "payment_reference" => "merchant-order-123",
      "reference" => "provider-statement-id" } }), name: "Wise payment", amount: 10, currency: "GBP",
      date: Date.current, source: "wise", external_id: "wise_statement_123")
    record = Abroa::ProviderSource.capture_existing!(entry)
    assert_equal "merchant-order-123", record.normalized.fetch("reference")
    assert_equal "linked", record.status
    assert_equal entry.id, record.entry_id
    assert_no_difference "Entry.count" do
      assert_equal record.id, Abroa::ProviderSource.capture_existing!(entry).id
    end
    unrelated = external_entry("not-wise")
    unrelated.transaction.update!(extra: { "wise" => { "payment_reference" => "untrusted" },
      "abroa" => { "reference" => "untrusted" } })
    assert_nil Abroa::ProviderSource.capture_existing!(unrelated).normalized.fetch("reference")
  end

  private
    def external_entry(id)
      @account.entries.create!(entryable: Transaction.new, name: "Provider entry", amount: 10, currency: "GBP",
        date: Date.current, source: "simplefin", external_id: id)
    end
end
