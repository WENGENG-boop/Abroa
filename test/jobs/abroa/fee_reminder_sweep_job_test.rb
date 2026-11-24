require "test_helper"

class Abroa::FeeReminderSweepJobTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Fee reminders", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2027-12-31" }, key: "fee-alert-project")
    @plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: {
      name: "Upcoming tuition", kind: "tuition", currency: "GBP",
      gross_amount: "1000", discount_amount: "100" }, key: "fee-alert-plan")
    @due = Abroa::FeeInstallment.schedule_for!(@user, @plan.id, attributes: {
      name: "Term bill", gross_amount: "1000", discount_amount: "100", due_on: "2026-11-26" }, key: "alert-term")
  end

  test "due soon and overdue events are durable, unique and never add ledger cash" do
    assert_no_difference "Entry.count" do
      assert_difference "Abroa::FeeReminderEvent.count", 1 do
        Abroa::FeeReminderSweepJob.new.perform(as_of: Date.new(2026, 11, 24))
      end
      assert_no_difference "Abroa::FeeReminderEvent.count" do
        Abroa::FeeReminderSweepJob.new.perform(as_of: Date.new(2026, 11, 24))
      end
      assert_difference "Abroa::FeeReminderEvent.count", 1 do
        Abroa::FeeReminderSweepJob.new.perform(as_of: Date.new(2026, 11, 27))
      end
      assert_no_difference "Abroa::FeeReminderEvent.count" do
        Abroa::FeeReminderSweepJob.new.perform(as_of: Date.new(2026, 11, 27))
      end
    end
    assert_equal %w[due_soon overdue], @due.reminder_events.order(:created_at).pluck(:kind)
    assert_equal [ @user.id ], @due.reminder_events.distinct.pluck(:recipient_id)
  end

  test "paid or cancelled installments do not produce fee reminder events" do
    @due.update!(state: "cancelled")
    Abroa::FeeReminderSweepJob.new.perform(as_of: Date.new(2026, 11, 24))
    assert_equal 0, Abroa::FeeReminderEvent.count
    @due.update!(state: "confirmed")
    Abroa::FeePlan.cancel_for!(@user, @plan.id, version: @plan.lock_version)
    Abroa::FeeReminderSweepJob.new.perform(as_of: Date.new(2026, 11, 24))
    assert_equal 0, Abroa::FeeReminderEvent.count
  end

  test "due date reschedule creates new scoped reminder without overwriting history" do
    Abroa::FeeReminderSweepJob.new.perform(as_of: Date.new(2026, 11, 24))
    Abroa::FeeInstallment.change_for!(@user, @due.id, version: @due.lock_version,
      attributes: { due_on: "2026-11-27" })
    Abroa::FeeReminderSweepJob.new.perform(as_of: Date.new(2026, 11, 25))
    assert_equal 2, @due.reminder_events.count
    assert_equal [ Date.new(2026, 11, 26), Date.new(2026, 11, 27) ],
      @due.reminder_events.order(:due_on).pluck(:due_on)
  end
end
