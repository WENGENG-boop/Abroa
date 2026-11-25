require "test_helper"
require "concurrent"
require "timeout"

class Abroa::NotificationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @student = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "Notification concurrency", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "p4-notification-concurrency")
    pref = Abroa::NotificationPreference.for_user(@student)
    pref.update_for!(@student, attributes: { email_enabled: true }, version: pref.lock_version)
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ids = Abroa::InboxNotification.where(source_type: "Abroa::StudyProject", source_id: @project.id).select(:id)
    Abroa::EmailOutbox.where(inbox_notification_id: ids).delete_all
    Abroa::InboxNotification.where(id: ids).delete_all
    Abroa::NotificationPreference.where(user_id: @student.id).delete_all
    @project.destroy!
    ActionMailer::Base.deliveries.clear
  end

  test "two independent PostgreSQL sessions can create only one notification and outbox per recipient/event" do
    result = race([ 1, 2 ]) do |_|
      Abroa::InboxNotification.emit_for!(
        recipient: User.find(@student.id), event_kind: "budget_risk",
        source: Abroa::StudyProject.find(@project.id),
        event_key: "two-session-same-event").id
    end
    assert_equal 1, result.map(&:first).uniq.size
    assert_equal 2, result.map(&:last).uniq.size
    item = Abroa::InboxNotification.where(source_id: @project.id).first!
    assert_equal 1, Abroa::InboxNotification.where(id: item.id).count
    assert_equal 1, Abroa::EmailOutbox.where(inbox_notification_id: item.id).count
  end

  test "concurrent worker executions cannot deliver the same outbox twice" do
    item = Abroa::InboxNotification.emit_for!(
      recipient: @student, event_kind: "budget_risk", source: @project, event_key: "concurrent-send")
    outbox = item.email_outbox
    result = race([ 1, 2 ]) do |_|
      Abroa::EmailOutboxDeliveryJob.new.perform(outbox.id)
      :attempted
    end
    assert_equal 2, result.map(&:last).uniq.size
    assert_equal "sent", outbox.reload.status
    assert_equal 1, outbox.attempt_count
    assert_equal 1, ActionMailer::Base.deliveries.count
  end

  private
    def race(items)
      latch = Concurrent::CountDownLatch.new(items.length)
      threads = items.map do |item|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            pid = ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
            latch.count_down
            raise "Barrier expired" unless latch.wait(15)
            [ yield(item), pid ]
          end
        end
      end
      Timeout.timeout(45) { threads.map(&:value) }
    ensure
      threads&.each { |thread| thread.kill if thread.alive?; thread.join }
    end
end
