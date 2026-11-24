require "test_helper"
require "stringio"

class Abroa::StatementIntakeTest < ActiveSupport::TestCase
  Upload = Struct.new(:original_filename, :content_type, :io) do
    def read(length)
      io.read(length)
    end

    def rewind
      io.rewind
    end
  end

  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Intake account", currency: "GBP", balance: 1000)
    csv = "Date,Amount,Description\n2025-01-10,-12.50,Cafe\n2025-01-10,-12.50,Cafe\n"
    @statement = AccountStatement.create_from_upload!(family: @user.family, account: @account,
      file: Upload.new("intake.csv", "text/csv", StringIO.new(csv)))
    @config = { source_kind: "generic_csv", mapping: { date: "Date", amount: "Amount",
      description: "Description", date_format: "%Y-%m-%d", signage: "inflows_positive" } }
  end

  test "preview is read only and publishing stages distinct rows exactly once" do
    preview = nil
    assert_no_difference [ "Abroa::StatementIntake.count", "Abroa::SourceRecord.count", "Entry.count" ] do
      preview = Abroa::StatementIntake.preview_for!(@user, statement_id: @statement.id, **@config)
    end
    assert_equal 2, preview.fetch(:record_count)
    assert_equal [], preview.fetch(:issues)
    receipt = nil
    assert_no_difference "Entry.count" do
      assert_difference({ "Abroa::StatementIntake.count" => 1, "Abroa::SourceRecord.count" => 2, "Abroa::SourceReview.count" => 2 }) do
        receipt = publish(preview)
      end
      assert_no_difference [ "Abroa::SourceRecord.count", "Abroa::SourceReview.count" ] do
        assert_equal receipt.id, publish(preview).id
      end
    end
    assert_equal 2, receipt.summary.fetch("review_count")
    assert_equal 2, Abroa::SourceObservation.where(statement: @statement).count
  end

  test "changed preview mapping and incorrect digest cannot publish" do
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: @statement.id, **@config)
    assert_no_difference [ "Abroa::SourceRecord.count", "Entry.count" ] do
      assert_raises(Abroa::StatementIntake::Conflict) do
        publish(preview.merge(preview_digest: "0" * 64))
      end
      changed = @config.deep_dup
      changed[:mapping][:signage] = "inflows_negative"
      assert_raises(Abroa::StatementIntake::Conflict) do
        Abroa::StatementIntake.publish_for!(@user, statement_id: @statement.id, **changed,
          preview_digest: preview.fetch(:preview_digest))
      end
    end
  end

  test "foreign tenant cannot preview or publish a private statement" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::StatementIntake.preview_for!(users(:empty), statement_id: @statement.id, **@config)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::StatementIntake.publish_for!(users(:empty), statement_id: @statement.id, **@config,
        preview_digest: "0" * 64)
    end
  end

  test "confirmed bank-funded statement links unique explicit reference without creating a ledger entry" do
    account, entry = bank_payment("match-one")
    statement = personal_statement(account, ["wallet-order"])
    config = { source_kind: "alipay_statement" }
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: statement.id, **config)
    assert_no_difference "Entry.count" do
      receipt = Abroa::StatementIntake.publish_for!(@user, statement_id: statement.id,
        preview_digest: preview.fetch(:preview_digest), **config)
      assert_equal 1, receipt.summary.fetch("auto_linked_count")
      assert_equal 0, receipt.summary.fetch("review_count")
      assert_equal receipt.id, Abroa::StatementIntake.publish_for!(@user, statement_id: statement.id,
        preview_digest: preview.fetch(:preview_digest), **config).id
    end
    source = Abroa::SourceRecord.find_by!(source_kind: "alipay_statement", external_id: "wallet-order")
    assert_equal "linked", source.status
    assert_equal entry.id, source.entry_id
    assert_equal "alipay", entry.reload.transaction.extra.dig("abroa", "payment_channel")
    assert_equal "Bank charge", entry.name
    assert_equal true, Abroa::SourceAction.find_by!(source_record: source).after_data.fetch("automatic")
  end

  test "ambiguous bank entries remain in review with no automatic mutation" do
    account, entry = bank_payment("match-one")
    account.entries.create!(entryable: Transaction.new, name: "Other charge", amount: 100,
      currency: "CNY", date: Date.new(2025, 1, 10))
    statement = personal_statement(account, ["wallet-order"])
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: statement.id, source_kind: "alipay_statement")
    assert_no_difference "Entry.count" do
      receipt = Abroa::StatementIntake.publish_for!(@user, statement_id: statement.id,
        source_kind: "alipay_statement", preview_digest: preview.fetch(:preview_digest))
      assert_equal 0, receipt.summary.fetch("auto_linked_count")
      assert_equal 1, receipt.summary.fetch("review_count")
    end
    assert_nil entry.reload.transaction.extra.dig("abroa", "payment_channel")
    assert_nil Abroa::SourceRecord.find_by!(source_kind: "alipay_statement", external_id: "wallet-order").entry_id
  end

  test "different orders sharing the same reference in one file do not auto-link" do
    account, entry = bank_payment("match-one")
    statement = personal_statement(account, ["wallet-one", "wallet-two"])
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: statement.id, source_kind: "alipay_statement")
    assert_no_difference "Entry.count" do
      receipt = Abroa::StatementIntake.publish_for!(@user, statement_id: statement.id,
        source_kind: "alipay_statement", preview_digest: preview.fetch(:preview_digest))
      assert_equal 0, receipt.summary.fetch("auto_linked_count")
      assert_equal 2, receipt.summary.fetch("review_count")
    end
    assert_nil entry.reload.transaction.extra.dig("abroa", "payment_channel")
  end

  test "batch rollback removes only its unchanged created entries and closes pending reviews" do
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: @statement.id, **@config)
    receipt = publish(preview)
    sources = Abroa::SourceRecord.where(statement: @statement).order(:id).to_a
    review = Abroa::SourceReview.find_by!(source_record: sources.first)
    action = Abroa::SourceReview.resolve_for!(@user, review_id: review.id, resolution: "create",
      expected_version: review.lock_version, key: "batch-create")
    assert_difference "Entry.count", -1 do
      assert_no_difference ["Abroa::SourceRecord.count", "Abroa::SourceObservation.count"] do
        result = Abroa::StatementIntake.rollback_for!(@user, statement_id: @statement.id)
        assert_equal receipt.id, result.id
        assert_equal "reversed", result.payload.fetch(:status)
      end
    end
    assert action.reload.reversed_at.present?
    assert_equal ["reversed"], sources.map { |source| source.reload.status }.uniq
    assert_not Abroa::SourceReview.where(source_record: sources, status: "pending").exists?
    assert_no_difference "Entry.count" do
      assert_equal receipt.id, Abroa::StatementIntake.rollback_for!(@user, statement_id: @statement.id).id
      assert_raises(Abroa::StatementIntake::Conflict) { publish(preview) }
    end
  end

  test "batch rollback is atomic if an entry was later modified" do
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: @statement.id, **@config)
    receipt = publish(preview)
    sources = Abroa::SourceRecord.where(statement: @statement).order(:id).to_a
    actions = sources.map do |source|
      review = Abroa::SourceReview.find_by!(source_record: source)
      Abroa::SourceReview.resolve_for!(@user, review_id: review.id, resolution: "create",
        expected_version: review.lock_version, key: "batch-#{source.id}")
    end
    actions.last.entry.update!(name: "Later edit")
    assert_no_difference "Entry.count" do
      assert_raises(Abroa::StatementIntake::Conflict, Abroa::SourceReview::Conflict) do
        Abroa::StatementIntake.rollback_for!(@user, statement_id: @statement.id)
      end
    end
    assert actions.none? { |action| action.reload.reversed_at.present? }
    assert_equal ["posted"], sources.map { |source| source.reload.status }.uniq
    assert_equal "staged", receipt.reload.payload.fetch(:status)
  end

  test "batch rollback of automatic link preserves existing bank transaction" do
    account, entry = bank_payment("match-one")
    statement = personal_statement(account, ["wallet-order"])
    config = { source_kind: "alipay_statement" }
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: statement.id, **config)
    Abroa::StatementIntake.publish_for!(@user, statement_id: statement.id,
      preview_digest: preview.fetch(:preview_digest), **config)
    assert_no_difference "Entry.count" do
      Abroa::StatementIntake.rollback_for!(@user, statement_id: statement.id)
    end
    assert_nil entry.reload.transaction.extra.dig("abroa", "payment_channel")
    assert_equal "Bank charge", entry.name
    assert_equal "linked", Abroa::SourceRecord.find_by!(entry: entry, source_kind: "bank_provider").status
  end

  test "later statement evidence blocks rollback of the original batch" do
    account, entry = bank_payment("match-one")
    config = { source_kind: "alipay_statement" }
    first = personal_statement(account, ["wallet-order"])
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: first.id, **config)
    receipt = Abroa::StatementIntake.publish_for!(@user, statement_id: first.id,
      preview_digest: preview.fetch(:preview_digest), **config)
    bytes = first.original_file.download + "\n"
    second = AccountStatement.create_from_upload!(family: @user.family, account: account,
      file: Upload.new("later.csv", "text/csv", StringIO.new(bytes)))
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: second.id, **config)
    Abroa::StatementIntake.publish_for!(@user, statement_id: second.id,
      preview_digest: preview.fetch(:preview_digest), **config)
    source = Abroa::SourceRecord.find_by!(source_kind: "alipay_statement", external_id: "wallet-order")
    assert_equal 2, source.observations.count
    assert_no_difference "Entry.count" do
      [first, second].each do |statement|
        assert_raises(Abroa::StatementIntake::Conflict) do
          Abroa::StatementIntake.rollback_for!(@user, statement_id: statement.id)
        end
      end
    end
    assert_equal "staged", receipt.reload.payload.fetch(:status)
    assert_equal "linked", source.reload.status
    assert_equal "alipay", entry.reload.transaction.extra.dig("abroa", "payment_channel")
  end

  test "unknown payment funding needs explicit account assignment before posting" do
    account, bank_entry = bank_payment("match-one")
    wallet = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Alipay balance", currency: "CNY", balance: 500)
    Abroa::AccountProfile.change_for!(@user, wallet.id, wallet_kind: "alipay")
    statement = personal_statement(account, ["unknown-order"], method: "现金")
    config = { source_kind: "alipay_statement" }
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: statement.id, **config)
    receipt = Abroa::StatementIntake.publish_for!(@user, statement_id: statement.id,
      preview_digest: preview.fetch(:preview_digest), **config)
    source = Abroa::SourceRecord.find_by!(statement: statement)
    review = Abroa::SourceReview.find_by!(source_record: source, status: "pending")
    assert_equal "unknown", source.normalized.fetch("funding_kind")
    assert_no_difference "Entry.count" do
      assert_raises(ArgumentError) do
        Abroa::SourceReview.resolve_for!(@user, review_id: review.id, resolution: "link",
          expected_version: review.lock_version, key: "unconfirmed-link", target_entry_id: bank_entry.id)
      end
      version = review.lock_version
      assigned = Abroa::SourceReview.assign_account_for!(@user, review_id: review.id,
        account_id: wallet.id, funding_kind: "wallet", expected_version: version)
      assert_equal wallet.id, source.reload.account_id
      assert_equal "unknown", source.normalized.fetch("funding_kind")
      assert_equal "wallet", assigned.evidence.dig("funding_assignment", "funding_kind")
      assert_raises(Abroa::SourceReview::Conflict) do
        Abroa::SourceReview.assign_account_for!(@user, review_id: review.id,
          account_id: account.id, funding_kind: "bank_account", expected_version: version)
      end
    end
    review.reload
    action = nil
    assert_difference "Entry.count", 1 do
      action = Abroa::SourceReview.resolve_for!(@user, review_id: review.id, resolution: "create",
        expected_version: review.lock_version, key: "assigned-wallet")
    end
    assert_equal wallet.id, action.entry.account_id
    assert_equal BigDecimal("100"), action.entry.amount
    assert_equal account.id, statement.reload.account_id
    assert_equal "Bank charge", bank_entry.reload.name
    assert_difference "Entry.count", -1 do
      Abroa::StatementIntake.rollback_for!(@user, statement_id: statement.id)
    end
    assert_equal "reversed", receipt.reload.payload.fetch(:status)
    assert Entry.exists?(bank_entry.id)
  end

  test "known wallet funding cannot be reassigned as a bank payment or to another tenant" do
    account, _entry = bank_payment("match-one")
    statement = personal_statement(account, ["wallet-order"], method: "余额")
    config = { source_kind: "alipay_statement" }
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: statement.id, **config)
    Abroa::StatementIntake.publish_for!(@user, statement_id: statement.id,
      preview_digest: preview.fetch(:preview_digest), **config)
    source = Abroa::SourceRecord.find_by!(statement: statement)
    review = Abroa::SourceReview.find_by!(source_record: source, status: "pending")
    other = users(:empty)
    foreign = Account.create!(family: other.family, owner: other, accountable: Depository.new,
      name: "Foreign", currency: "CNY", balance: 100)
    assert_raises(ArgumentError) do
      Abroa::SourceReview.assign_account_for!(@user, review_id: review.id,
        account_id: account.id, funding_kind: "bank_account", expected_version: review.lock_version)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::SourceReview.assign_account_for!(@user, review_id: review.id,
        account_id: foreign.id, funding_kind: "wallet", expected_version: review.lock_version)
    end
    assert_equal account.id, source.reload.account_id
  end

  test "manual automation preference stages high confidence match without writing metadata" do
    Abroa::Profile.change_for!(@user, version: 0, attributes: { import_automation: "manual" })
    account, entry = bank_payment("match-one")
    statement = personal_statement(account, ["wallet-order"])
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: statement.id, source_kind: "alipay_statement")
    receipt = Abroa::StatementIntake.publish_for!(@user, statement_id: statement.id,
      source_kind: "alipay_statement", preview_digest: preview.fetch(:preview_digest))
    assert_equal 0, receipt.summary.fetch("auto_linked_count")
    assert_equal 1, receipt.summary.fetch("review_count")
    assert_nil entry.reload.transaction.extra.dig("abroa", "payment_channel")
  end

  test "explicit matching category rule classifies newly confirmed movement without changing amount" do
    category = @user.family.categories.create!(name: "Cafe imports", color: "#6471eb", lucide_icon: "coffee")
    @user.family.rules.create!(name: "Exact cafe", resource_type: "transaction", active: true,
      apply_immediately: true, effective_date: Date.new(2024, 1, 1),
      conditions_attributes: [{condition_type: "transaction_name", operator: "=", value: "Cafe"}],
      actions_attributes: [{action_type: "set_transaction_category", value: category.id}])
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: @statement.id, **@config)
    publish(preview)
    source = Abroa::SourceRecord.where(statement: @statement).first
    review = Abroa::SourceReview.find_by!(source_record: source)
    action = Abroa::SourceReview.resolve_for!(@user, review_id: review.id, resolution: "create",
      expected_version: review.lock_version, key: "classify-cafe")
    assert_equal category.id, action.entry.transaction.category_id
    assert_equal BigDecimal("12.5"), action.entry.amount
    assert_equal "classified", action.after_data.fetch("classification_status")
    assert_equal "rule", action.entry.transaction.data_enrichments.where(attribute_name: "category_id").last.source
  end

  test "automatic category never replaces locked uncategorized entry or manually selected category" do
    category = @user.family.categories.create!(name: "Protected cafe", color: "#6471eb", lucide_icon: "coffee")
    @user.family.rules.create!(name: "Cafe protection", resource_type: "transaction", active: true,
      apply_immediately: true, effective_date: Date.new(2024, 1, 1),
      conditions_attributes: [{condition_type: "transaction_name", operator: "=", value: "Cafe"}],
      actions_attributes: [{action_type: "set_transaction_category", value: category.id}])
    entry = @account.entries.create!(name: "Cafe", amount: 12.5, currency: "GBP", date: Date.new(2025, 1, 10),
      entryable: Transaction.new)
    entry.transaction.lock_attr!(:category_id)
    assert_equal "locked", Abroa::ImportClassification.apply_for!(@user, entry)
    assert_nil entry.reload.transaction.category_id
    assert entry.transaction.locked?(:category_id)
    entry.transaction.unlock_attr!(:category_id)
    manual = @user.family.categories.create!(name: "Manual cafe", color: "#6471eb", lucide_icon: "coffee")
    entry.transaction.update!(category: manual)
    assert_equal "already_classified", Abroa::ImportClassification.apply_for!(@user, entry)
    assert_equal manual.id, entry.reload.transaction.category_id
  end

  test "bank statement reconciliation requires exact balances and complete ledger evidence" do
    receipt, rows = reconcilable_statement
    preview = Abroa::StatementReconciliation.preview_for!(@user, statement_id: @statement.id)
    assert_equal "ready", preview.fetch(:status)
    assert_equal 2, preview.fetch(:entry_count)
    assert rows.none?(&:statement_reconciled?)
    assert_no_difference ["Entry.count", "Balance.count"] do
      result = Abroa::StatementReconciliation.confirm_for!(@user, statement_id: @statement.id,
        digest: preview.fetch(:digest))
      assert_equal "reconciled", result.fetch(:status)
      assert_equal result, Abroa::StatementReconciliation.confirm_for!(@user, statement_id: @statement.id,
        digest: preview.fetch(:digest))
      assert rows.all? { |row| row.reload.reconciled_by_statement_id == @statement.id }
      assert_raises(Abroa::StatementIntake::Conflict) do
        Abroa::StatementIntake.rollback_for!(@user, statement_id: @statement.id)
      end
      result = Abroa::StatementReconciliation.undo_for!(@user, statement_id: @statement.id)
      assert_equal "reversed", result.fetch(:status)
      assert_equal result, Abroa::StatementReconciliation.undo_for!(@user, statement_id: @statement.id)
    end
    assert rows.none? { |row| row.reload.statement_reconciled? }
    assert_equal 1, receipt.reload.summary.fetch("reconciliation_history").size
  end

  test "reconciliation refuses missing movements, stale previews, and changed balance" do
    _receipt, rows = reconcilable_statement
    preview = Abroa::StatementReconciliation.preview_for!(@user, statement_id: @statement.id)
    rows.last.update!(amount: 13)
    assert_raises(Abroa::StatementIntake::Conflict) do
      Abroa::StatementReconciliation.confirm_for!(@user, statement_id: @statement.id, digest: preview.fetch(:digest))
    end
    assert rows.none? { |row| row.reload.statement_reconciled? }
    rows.last.update!(amount: 12.5)
    @account.entries.create!(entryable: Transaction.new, name: "Not in statement", amount: 1,
      currency: "GBP", date: Date.new(2025, 1, 10))
    preview = Abroa::StatementReconciliation.preview_for!(@user, statement_id: @statement.id)
    assert_equal "review", preview.fetch(:status)
    assert_includes preview.fetch(:issues), "unmatched_ledger_entries"
    assert_raises(Abroa::StatementIntake::Conflict) do
      Abroa::StatementReconciliation.confirm_for!(@user, statement_id: @statement.id, digest: preview.fetch(:digest))
    end
  end

  test "reconciliation undo protects later manual edits and requires authorized statement access" do
    _receipt, rows = reconcilable_statement
    preview = Abroa::StatementReconciliation.preview_for!(@user, statement_id: @statement.id)
    Abroa::StatementReconciliation.confirm_for!(@user, statement_id: @statement.id, digest: preview.fetch(:digest))
    rows.last.update!(name: "Edited later")
    assert_raises(Abroa::StatementIntake::Conflict) do
      Abroa::StatementReconciliation.undo_for!(@user, statement_id: @statement.id)
    end
    assert rows.all? { |row| row.reload.statement_reconciled? }
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::StatementReconciliation.preview_for!(users(:empty), statement_id: @statement.id)
    end
  end

  private
    def reconcilable_statement
      @config[:source_kind] = "bank_statement"
      day = Date.new(2025, 1, 10)
      @statement.update!(period_start_on: day, period_end_on: day, opening_balance: 1000,
        closing_balance: 975, currency: "GBP")
      @account.balances.create!(date: day, currency: "GBP", balance: 975, cash_balance: 975,
        start_cash_balance: 1000, cash_outflows: 25)
      preview = Abroa::StatementIntake.preview_for!(@user, statement_id: @statement.id, **@config)
      receipt = publish(preview)
      entries = Abroa::SourceRecord.where(statement: @statement).order(:id).map do |source|
        review = Abroa::SourceReview.find_by!(source_record: source)
        Abroa::SourceReview.resolve_for!(@user, review_id: review.id, resolution: "create",
          expected_version: review.lock_version, key: "reconcile-#{source.id}").entry
      end
      [receipt, entries]
    end

    def bank_payment(reference)
      account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
        name: "CNY bank", currency: "CNY", balance: 1000)
      entry = account.entries.create!(entryable: Transaction.new, name: "Bank charge", amount: 100,
        currency: "CNY", date: Date.new(2025, 1, 10), source: "test-provider", external_id: "bank-one")
      normalized = Abroa::NormalizedSource.build(
        source_kind: "bank_provider", source_instance_key: "test-bank",
        source_row_key: "provider:bank-one", external_id: "bank-one",
        raw_digest: Digest::SHA256.hexdigest("bank-one"), local_date: entry.date,
        amount: "100", currency: "CNY", direction: "outflow", provider_status: "posted",
        transaction_kind: "payment", description: "Bank charge", provider_name: entry.source, reference: reference
      )
      record = Abroa::SourceRecord.ingest!(family: @user.family, account: account, record: normalized)
      record.link_existing_provider_entry!(entry)
      [ account, entry ]
    end

    def personal_statement(account, orders, method: "银行卡")
      header = "交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注\n"
      rows = orders.map { |order| "2025-01-10 10:00:00,购物,测试商户,,商品,支出,100.00,#{method},交易成功,#{order},match-one,\n" }
      AccountStatement.create_from_upload!(family: @user.family, account: account,
        file: Upload.new("wallet.csv", "text/csv", StringIO.new(header + rows.join)))
    end

    def publish(preview)
      Abroa::StatementIntake.publish_for!(@user, statement_id: @statement.id, **@config,
        preview_digest: preview.fetch(:preview_digest))
    end
end
