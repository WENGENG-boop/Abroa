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

  private
    def publish(preview)
      Abroa::StatementIntake.publish_for!(@user, statement_id: @statement.id, **@config,
        preview_digest: preview.fetch(:preview_digest))
    end
end
