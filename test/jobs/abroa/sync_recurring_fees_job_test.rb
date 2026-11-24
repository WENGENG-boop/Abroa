require "test_helper"

class Abroa::SyncRecurringFeesJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @source = recurring_transactions(:netflix_subscription)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Scheduled synchronization", country: "GB", currency: "USD", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2027-12-31" }, key: "fee-sync-project")
    @plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: {
      name: "Recurring tuition", kind: "tuition", currency: "USD", gross_amount: "6000",
      discount_amount: "0", recurring_transaction_id: @source.id
    }, key: "fee-sync-plan")
    @occurrence = RecurringOccurrence.create!(family: @user.family, recurring_transaction: @source,
      original_due_on: Date.new(2026, 12, 1), due_on: Date.new(2026, 12, 1),
      currency: "USD", expected_amount: 1200, status: "scheduled")
  end

  test "automatic scheduled sync imports a bill once without adding a bank entry" do
    assert_no_difference "Entry.count" do
      assert_difference "Abroa::FeeInstallment.count", 1 do
        Abroa::SyncRecurringFeesJob.new.perform(@plan.id, as_of: Date.new(2026, 11, 24))
      end
      assert_no_difference "Abroa::FeeInstallment.count" do
        Abroa::SyncRecurringFeesJob.new.perform(@plan.id, as_of: Date.new(2026, 11, 24))
      end
    end
    assert_equal @occurrence.id, @plan.installments.first.recurring_occurrence_id
    assert_equal BigDecimal("1200"), @plan.installments.first.net_amount
  end

  test "skipped occurrences do not create liabilities, no backfill past bound" do
    @occurrence.update!(status: "skipped", closed_at: Time.current, closed_source: "user")
    Abroa::SyncRecurringFeesJob.new.perform(@plan.id, as_of: Date.new(2026, 11, 24))
    assert_equal 0, @plan.installments.count
    @occurrence.update!(status: "scheduled", closed_at: nil, closed_source: nil)
    Abroa::SyncRecurringFeesJob.new.perform(@plan.id, as_of: Date.new(2027, 7, 1))
    assert_equal 0, @plan.installments.count
  end

  test "revoked source-account access blocks background sync without bypassing authorization" do
    accounts(:depository).update!(owner: users(:family_member))
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::SyncRecurringFeesJob.new.perform(@plan.id, as_of: Date.new(2026, 11, 24))
    end
    assert_equal 0, @plan.installments.count
  end

  test "fan-out enqueues eligible fee plans without directly importing" do
    assert_enqueued_with(job: Abroa::SyncRecurringFeesJob, args: [ @plan.id ]) do
      Abroa::SyncRecurringFeesJob.new.perform
    end
    assert_equal 0, @plan.installments.count
  end
end
