require "test_helper"

class Abroa::FeeRecurringImportTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @source = recurring_transactions(:netflix_subscription)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Recurring study", country: "GB", currency: "USD", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2027-12-31" }, key: "recurring-fee-project")
    @plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: {
      name: "Scheduled rent", kind: "rent", currency: "USD",
      gross_amount: "5000", discount_amount: "0", recurring_transaction_id: @source.id
    }, key: "recurring-fee")
    @occurrence = RecurringOccurrence.create!(family: @user.family, recurring_transaction: @source,
      original_due_on: Date.new(2025, 9, 1), due_on: Date.new(2025, 9, 1),
      currency: "USD", expected_amount: 1200, status: "scheduled")
  end

  test "imports Sure recurring occurrence once without creating a bank entry" do
    assert_no_difference "Entry.count" do
      imported = Abroa::FeeInstallment.import_recurring_for!(@user, @plan.id,
        from_on: "2025-09-01", through_on: "2025-10-31")
      assert_equal 1, imported.size
      assert_equal @occurrence.id, imported.first.recurring_occurrence_id
      assert_equal BigDecimal("1200"), imported.first.net_amount
      assert_equal Date.new(2025, 9, 1), imported.first.due_on
      repeated = Abroa::FeeInstallment.import_recurring_for!(@user, @plan.id,
        from_on: "2025-09-01", through_on: "2025-10-31")
      assert_equal [ imported.first.id ], repeated.map(&:id)
    end
    assert_equal 1, @plan.installments.count
  end

  test "snoozed Sure occurrences are imported when the effective due date is in range" do
    @occurrence.update!(snoozed_until: Date.new(2025, 10, 3))
    imported = Abroa::FeeInstallment.import_recurring_for!(@user, @plan.id,
      from_on: "2025-10-01", through_on: "2025-10-31")
    assert_equal [ @occurrence.id ], imported.map(&:recurring_occurrence_id)
    assert_equal Date.new(2025, 10, 3), imported.first.due_on
    assert_equal 1, @plan.installments.count
  end

  test "skipped occurrences do not create future liabilities" do
    @occurrence.update!(status: "skipped", closed_at: Time.current, closed_source: "user")
    imported = Abroa::FeeInstallment.import_recurring_for!(@user, @plan.id,
      from_on: "2025-09-01", through_on: "2025-10-31")
    assert_empty imported
    assert_equal 0, @plan.installments.count
  end

  test "revoked account access refuses importing someone else's bill" do
    accounts(:depository).update!(owner: users(:family_member))
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::FeeInstallment.import_recurring_for!(@user, @plan.id,
        from_on: "2025-09-01", through_on: "2025-10-31")
    end
  end

  test "different currency and excessive ranges fail closed without guessed FX" do
    @plan.update!(currency: "GBP")
    assert_raises(ArgumentError) do
      Abroa::FeeInstallment.import_recurring_for!(@user, @plan.id,
        from_on: "2025-09-01", through_on: "2025-10-31")
    end
    assert_raises(ArgumentError) do
      Abroa::FeeInstallment.import_recurring_for!(@user, @plan.id,
        from_on: "2025-01-01", through_on: "2027-12-31")
    end
    assert_equal 0, @plan.installments.count
  end
end
