require "test_helper"

class Abroa::SourceMatcherTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = Account.create!(family: @family, owner: @user, accountable: Depository.new,
      name: "Matching bank account", currency: "CNY", balance: 1000)
  end

  test "equal date and amount without shared reference never authorize a link" do
    entry = bank_entry("bank-one")
    bank_evidence(entry, reference: nil)
    source = wallet_evidence(reference: "merchant-one")
    assert_no_difference [ "Entry.count", "Abroa::SourceRecord.count" ] do
      result = Abroa::SourceMatcher.call(user: @user, source: source)
      assert_equal "review", result.action
      assert_equal [ entry.id ], result.candidate_ids
      assert_nil result.entry_id
    end
    assert_nil source.reload.entry_id
  end

  test "unique bank evidence and matching explicit reference propose a link without writing" do
    entry = bank_entry("bank-one")
    bank_evidence(entry, reference: "merchant-one")
    source = wallet_evidence(reference: "merchant-one")
    result = Abroa::SourceMatcher.call(user: @user, source: source)
    assert_equal "link", result.action
    assert_equal entry.id, result.entry_id
    assert_nil source.reload.entry_id
    assert_equal "Bank charge", entry.reload.name
  end

  test "multiple same amount candidates always require review" do
    first = bank_entry("bank-one")
    second = bank_entry("bank-two")
    bank_evidence(first, reference: "merchant-one")
    bank_evidence(second, reference: "different")
    result = Abroa::SourceMatcher.call(user: @user, source: wallet_evidence(reference: "merchant-one"))
    assert_equal "review", result.action
    assert_equal [ first.id, second.id ].sort, result.candidate_ids.sort
  end

  test "a wallet balance payment is not eligible for bank linking" do
    entry = bank_entry("bank-one")
    bank_evidence(entry, reference: "merchant-one")
    result = Abroa::SourceMatcher.call(user: @user,
      source: wallet_evidence(reference: "merchant-one", funding_kind: "wallet"))
    assert_equal "review", result.action
    assert_nil result.entry_id
  end

  test "unrelated tenants cannot examine match candidates" do
    source = wallet_evidence(reference: "merchant-one")
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::SourceMatcher.call(user: users(:empty), source: source)
    end
  end

  private
    def bank_entry(external_id)
      @account.entries.create!(entryable: Transaction.new, name: "Bank charge", amount: 100,
        currency: "CNY", date: Date.new(2025, 1, 10), source: "test-provider", external_id: external_id)
    end

    def bank_evidence(entry, reference:)
      normalized = Abroa::NormalizedSource.build(
        source_kind: "bank_provider", source_instance_key: "test-bank",
        source_row_key: "provider:#{entry.external_id}", external_id: entry.external_id,
        raw_digest: Digest::SHA256.hexdigest(entry.external_id), local_date: entry.date,
        amount: "100", currency: "CNY", direction: "outflow", provider_status: "posted",
        transaction_kind: "payment", description: "Bank charge", provider_name: entry.source, reference: reference
      )
      record = Abroa::SourceRecord.ingest!(family: @family, account: @account, record: normalized)
      record.link_existing_provider_entry!(entry)
    end

    def wallet_evidence(reference:, funding_kind: "bank_account")
      normalized = Abroa::NormalizedSource.build(
        source_kind: "alipay_statement", source_instance_key: "personal-alipay", source_row_key: "file:1",
        external_id: "wallet-order", raw_digest: Digest::SHA256.hexdigest("wallet-order"),
        local_date: Date.new(2025, 1, 10), amount: "100", currency: "CNY", direction: "outflow",
        provider_status: "posted", transaction_kind: "payment", description: "Store",
        payment_channel: "alipay", funding_kind: funding_kind, reference: reference
      )
      Abroa::SourceRecord.ingest!(family: @family, account: @account, record: normalized)
    end
end
