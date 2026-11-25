require "test_helper"

class Abroa::NotificationEventSweepTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "Notification events", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-01-01" },
      key: "notification-events-project")
  end

  test "P2 posted fee reminder becomes one inbox item under repeated sweeps" do
    plan = Abroa::FeePlan.create_for!(@student, @project.id,
      attributes: { name: "Rent due", kind: "rent", currency: "GBP",
        gross_amount: "600", discount_amount: "0" }, key: "notification-fee-plan")
    installment = Abroa::FeeInstallment.schedule_for!(@student, plan.id,
      attributes: { name: "Rent", due_on: (Date.current + 1).iso8601,
        gross_amount: "600", discount_amount: "0", state: "confirmed" }, key: "notification-fee-installment")
    event = Abroa::FeeReminderEvent.emit_for!(installment, recipient: @student, kind: "due_soon")
    job = Abroa::NotificationEventSweepJob.new
    job.perform(as_of: Date.current.iso8601)
    item = Abroa::InboxNotification.for_user(@student).find_by!(
      event_kind: "fee_due", source_id: event.id)
    job.perform(as_of: Date.current.iso8601)
    assert_equal 1, Abroa::InboxNotification.for_user(@student).where(
      event_kind: "fee_due", source_id: event.id).count
    assert_equal "unread", item.state
  end

  test "grant creation and revoke generate distinct safe events for current parent and student" do
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    _invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "notify-relationship")
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    grant = Abroa::Grant.create_for!(@student, relation.id, project_id: @project.id,
      capability: "summary", key: "notify-grant")
    Abroa::NotificationEventSweepJob.new.perform(as_of: Date.current.iso8601)
    assert Abroa::InboxNotification.for_user(@parent).where(
      event_kind: "grant_change", source_id: grant.id).exists?
    first_count = Abroa::InboxNotification.for_user(@parent).where(
      event_kind: "grant_change", source_id: grant.id).count
    Abroa::Grant.revoke_for!(@student, relation.id, grant.id, version: grant.lock_version)
    Abroa::NotificationEventSweepJob.new.perform(as_of: Date.current.iso8601)
    assert_equal first_count + 1, Abroa::InboxNotification.for_user(@parent).where(
      event_kind: "grant_change", source_id: grant.id).count
    assert_not_includes Abroa::InboxNotification.for_user(@parent).last.payload.to_json, @project.name
  end

  test "retry worker polls pending outboxes and will not queue duplicates after sending" do
    prefs = Abroa::NotificationPreference.for_user(@student)
    prefs.update_for!(@student, attributes: { email_enabled: true }, version: prefs.lock_version)
    item = Abroa::InboxNotification.emit_for!(recipient: @student,
      event_kind: "budget_risk", source: @project, event_key: "scheduled-email")
    assert_equal "pending", item.email_outbox.status
    assert_difference -> { enqueued_jobs.count }, 1 do
      Abroa::EmailOutboxSweepJob.perform_now
    end
    Abroa::EmailOutboxDeliveryJob.perform_now(item.email_outbox.id)
    assert_equal "sent", item.email_outbox.reload.status
    assert_no_difference -> { enqueued_jobs.count } do
      Abroa::EmailOutboxSweepJob.perform_now
    end
  end

  test "worker crash while SMTP acceptance is uncertain never triggers a blind resend" do
    prefs = Abroa::NotificationPreference.for_user(@student)
    prefs.update_for!(@student, attributes: { email_enabled: true }, version: prefs.lock_version)
    item = Abroa::InboxNotification.emit_for!(recipient: @student,
      event_kind: "budget_risk", source: @project, event_key: "crashed-during-send")
    outbox = item.email_outbox
    outbox.update_columns(status: "sending", attempt_count: 1,
      updated_at: 30.minutes.ago)
    Abroa::EmailOutboxRecoveryJob.perform_now
    assert_equal "uncertain", outbox.reload.status
    assert_no_difference -> { enqueued_jobs.count } do
      Abroa::EmailOutboxSweepJob.perform_now
    end
    Abroa::EmailOutboxDeliveryJob.perform_now(outbox.id)
    assert_equal "uncertain", outbox.reload.status
  end

  test "fatal SMTP refusal leaves a bounded retryable failure without private error details" do
    prefs = Abroa::NotificationPreference.for_user(@student)
    prefs.update_for!(@student, attributes: { email_enabled: true }, version: prefs.lock_version)
    item = Abroa::InboxNotification.emit_for!(recipient: @student,
      event_kind: "budget_risk", source: @project, event_key: "smtp-failure")
    failure = ->(**_kwargs) { raise Net::SMTPFatalError, "confidential server response" }
    AbroaNotificationMailer.stub(:generic, failure) do
      Abroa::EmailOutboxDeliveryJob.perform_now(item.email_outbox.id)
    end
    outbox = item.email_outbox.reload
    assert_equal "failed", outbox.status
    assert_equal 1, outbox.attempt_count
    assert_not_includes outbox.error_code.to_s, "confidential"
    outbox.update!(next_retry_at: Time.current - 1.minute)
    Abroa::EmailOutboxDeliveryJob.perform_now(outbox.id)
    assert_equal "sent", outbox.reload.status
  end
end
