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

  private
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

    def personal_statement(account, orders)
      header = "交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注\n"
      rows = orders.map { |order| "2025-01-10 10:00:00,购物,测试商户,,商品,支出,100.00,银行卡,交易成功,#{order},match-one,\n" }
      AccountStatement.create_from_upload!(family: @user.family, account: account,
        file: Upload.new("wallet.csv", "text/csv", StringIO.new(header + rows.join)))
    end

    def publish(preview)
      Abroa::StatementIntake.publish_for!(@user, statement_id: @statement.id, **@config,
        preview_digest: preview.fetch(:preview_digest))
    end
end
