module Abroa
  # Rechecks tenant, preference and current source/Grant at execution time.
  # Safe restart: only pending/known-failed rows may send; sending rows need
  # explicit delivery reconciliation before replay (SMTP acceptance unknown).
  class EmailOutboxDeliveryJob < ApplicationJob
    queue_as :medium_priority
    MAX_ATTEMPTS = 5

    def perform(id)
      outbox = EmailOutbox.find_by(id: id)
      return unless outbox
      recipient = nil
      deliver = false
      outbox.with_lock do
        return if %w[sent cancelled sending uncertain].include?(outbox.status)
        return if outbox.next_retry_at && outbox.next_retry_at > Time.current
        if outbox.inbox_notification.recipient_id != outbox.recipient_id ||
            outbox.inbox_notification.family_id != outbox.family_id ||
            outbox.recipient.family_id != outbox.family_id
          outbox.update_columns(status: "cancelled", error_code: "invalid_recipient",
            updated_at: Time.current)
          return
        end
        pref = NotificationPreference.for_user(outbox.recipient) if outbox.recipient&.active?
        if !pref || !pref.email_enabled || !outbox.inbox_notification.authorized_for?(outbox.recipient)
          outbox.update!(status: "cancelled", error_code: "permission_or_preference_revoked")
          return
        end
        if pref.quiet_now?
          outbox.update!(next_retry_at: Time.current + 1.hour)
          return
        end
        if outbox.attempt_count >= MAX_ATTEMPTS
          outbox.update!(status: "cancelled", error_code: "retry_limit")
          return
        end
        recipient = outbox.recipient
        outbox.update!(status: "sending", attempt_count: outbox.attempt_count + 1,
          next_retry_at: nil, error_code: nil)
        deliver = true
      end
      return unless deliver

      # Validate once more at the actual send boundary. No sensitive source
      # details or customer-defined strings are ever included in the mail.
      unless outbox.reload.inbox_notification.authorized_for?(recipient) &&
          NotificationPreference.for_user(recipient).email_enabled
        outbox.with_lock { outbox.update!(status: "cancelled", error_code: "permission_revoked") }
        return
      end

      AbroaNotificationMailer.generic(recipient: recipient).deliver_now
      outbox.with_lock { outbox.update!(status: "sent", sent_at: Time.current) }
    rescue Net::SMTPFatalError, Net::SMTPServerBusy, Net::SMTPAuthenticationError => e
      # Explicit SMTP refusal: no successful acceptance; a capped retry is safe.
      outbox&.with_lock do
        if outbox.status == "sending"
          outbox.update!(status: "failed",
            error_code: e.class.name.split("::").last.slice(0, 70),
            next_retry_at: Time.current + outbox.attempt_count.hours)
        end
      end
    rescue StandardError => e
      # Timeouts/transport failures may have been delivered remotely. Do not
      # automatically resend an ambiguous message after worker restart.
      outbox&.with_lock do
        if outbox.status == "sending"
          outbox.update!(status: "uncertain",
            error_code: "ambiguous_delivery")
        end
      end
      Rails.logger.warn("Abroa notification delivery uncertain (#{e.class.name})")
    end
  end
end
