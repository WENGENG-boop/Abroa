require "test_helper"

class Abroa::InboxNotificationTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @other = users(:empty)
    @project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "P4 inbox test project", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-01-01" },
      key: "p4-inbox-project")
    ActionMailer::Base.deliveries.clear
  end

  test "same stable event key creates exactly one tenant-scoped inbox item" do
    first = event("risk-event")
    second = event("risk-event")
    assert_equal first.id, second.id
    assert_equal 1, Abroa::InboxNotification.for_user(@student).where(event_kind: "budget_risk").count
    assert_equal "unread", first.state
    first.mark_read_for!(@student)
    assert_equal "read", first.reload.state
    first.mark_read_for!(@student)
    assert_equal 1, Abroa::InboxNotification.where(id: first.id).count
    assert_raises(ActiveRecord::RecordNotFound) do
      first.mark_read_for!(@other)
    end
  end

  test "default email opt-out creates no outbound mail" do
    item = event("email-opt-out")
    assert_equal false, Abroa::NotificationPreference.for_user(@student).email_enabled
    assert_nil item.email_outbox
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  test "email opt-in creates durable outbox and retry after successful delivery is idempotent" do
    pref = Abroa::NotificationPreference.for_user(@student)
    pref.update_for!(@student, attributes: { email_enabled: true }, version: pref.lock_version)
    item = event("email-opt-in")
    outbox = item.email_outbox
    assert outbox.persisted?
    assert_equal "pending", outbox.status
    Abroa::EmailOutboxDeliveryJob.new.perform(outbox.id)
    assert_equal "sent", outbox.reload.status
    assert_equal 1, ActionMailer::Base.deliveries.count
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ @student.email ], mail.to
    assert_not_includes mail.body.decoded, @project.name
    assert_not_includes mail.body.decoded, "600 GBP"
    Abroa::EmailOutboxDeliveryJob.new.perform(outbox.id)
    assert_equal 1, ActionMailer::Base.deliveries.count
    assert_equal 1, Abroa::EmailOutbox.where(inbox_notification_id: item.id).count
  end

  test "disabled preferences or permission revoked before worker execution blocks email" do
    pref = Abroa::NotificationPreference.for_user(@student)
    pref.update_for!(@student, attributes: { email_enabled: true }, version: pref.lock_version)
    item = event("permission-changed")
    pref.reload.update_for!(@student, attributes: { email_enabled: false }, version: pref.lock_version)
    Abroa::EmailOutboxDeliveryJob.new.perform(item.email_outbox.id)
    assert_equal "cancelled", item.email_outbox.reload.status
    assert_equal 0, ActionMailer::Base.deliveries.count
  end

  test "cross-timezone quiet hours defer mail and a later allowed hour resumes it" do
    pref = Abroa::NotificationPreference.for_user(@student)
    pref.update_for!(@student,
      attributes: { email_enabled: true, timezone: "Asia/Tokyo",
        quiet_start_hour: 23, quiet_end_hour: 7 }, version: pref.lock_version)
    item = event("tokyo-midnight")
    travel_to(Time.utc(2026, 11, 25, 15, 30)) do
      Abroa::EmailOutboxDeliveryJob.new.perform(item.email_outbox.id)
      assert_equal "pending", item.email_outbox.reload.status
      assert item.email_outbox.next_retry_at.present?
      assert_empty ActionMailer::Base.deliveries
    end
    pref.reload.update_for!(@student,
      attributes: { quiet_start_hour: nil, quiet_end_hour: nil }, version: pref.lock_version)
    item.email_outbox.reload.update!(next_retry_at: Time.current - 1.minute)
    Abroa::EmailOutboxDeliveryJob.new.perform(item.email_outbox.id)
    assert_equal "sent", item.email_outbox.reload.status
    assert_equal 1, ActionMailer::Base.deliveries.count
  end

  test "disabling in-app channel prevents event display even when event already exists" do
    item = event("hidden-inapp")
    pref = Abroa::NotificationPreference.for_user(@student)
    pref.update_for!(@student,
      attributes: { in_app_enabled: false }, version: pref.lock_version)
    assert_equal false, pref.reload.in_app_enabled
    assert_equal "unread", item.reload.state
    assert_raises(ActiveRecord::RecordNotFound) { item.mark_read_for!(@student) }
  end

  test "recipient spoofing across families never creates a notification or sends mail" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::InboxNotification.emit_for!(recipient: @other, event_kind: "budget_risk",
        source: @project, event_key: "spoofed-cross-tenant")
    end
    assert_equal 0, Abroa::InboxNotification.for_user(@other).count
    assert_empty ActionMailer::Base.deliveries
  end

  test "worker will not deliver when outbox recipient is corrupted to another family" do
    pref = Abroa::NotificationPreference.for_user(@student)
    pref.update_for!(@student, attributes: { email_enabled: true }, version: pref.lock_version)
    outsider_pref = Abroa::NotificationPreference.for_user(@other)
    outsider_pref.update_for!(@other, attributes: { email_enabled: true },
      version: outsider_pref.lock_version)
    item = event("tampered-recipient")
    outbox = item.email_outbox
    outbox.update_columns(recipient_id: @other.id)
    Abroa::EmailOutboxDeliveryJob.new.perform(outbox.id)
    assert_equal "cancelled", outbox.reload.status
    assert_empty ActionMailer::Base.deliveries
  end

  test "email job must recheck an active parental grant" do
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @other, student_enabled: false, parent_enabled: true)
    _invite, token = Abroa::RelationshipInvite.issue_for!(@other,
      recipient_email: @student.email, recipient_role: "student", key: "p4-inbox-relation")
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    grant = Abroa::Grant.create_for!(@student, relation.id,
      project_id: @project.id, capability: "summary", key: "p4-inbox-parent-grant")
    prefs = Abroa::NotificationPreference.for_user(@other)
    prefs.update_for!(@other, attributes: { email_enabled: true }, version: prefs.lock_version)
    item = Abroa::InboxNotification.emit_for!(recipient: @other,
      event_kind: "grant_change", source: @project, event_key: "parent-revoke-risk")
    assert item.email_outbox
    Abroa::Grant.revoke_for!(@student, relation.id, grant.id, version: grant.lock_version)
    Abroa::EmailOutboxDeliveryJob.new.perform(item.email_outbox.id)
    assert_equal "cancelled", item.email_outbox.reload.status
    assert_empty ActionMailer::Base.deliveries
  end

  private
    def event(key)
      Abroa::InboxNotification.emit_for!(recipient: @student,
        event_kind: "budget_risk", source: @project, event_key: key)
    end
end
