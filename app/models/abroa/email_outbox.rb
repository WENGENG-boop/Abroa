module Abroa
  # Persistent delivery intent: no user content or addresses are stored here.
  # A sending row is deliberately not auto-retried after a worker crash:
  # whether an external SMTP server accepted it may be unknowable.
  class EmailOutbox < ApplicationRecord
    self.table_name = "abroa_email_outboxes"

    belongs_to :family
    belongs_to :recipient, class_name: "User"
    belongs_to :inbox_notification, class_name: "Abroa::InboxNotification"

    validates :status, inclusion: { in: %w[pending sending sent failed cancelled uncertain] }
    validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :same_tenant

    def eligible_now?
      return false unless recipient&.active? && !recipient.guest? &&
        recipient.family_id == family_id && recipient.email.present? &&
        inbox_notification.recipient_id == recipient_id &&
        inbox_notification.family_id == family_id &&
        inbox_notification.authorized_for?(recipient)
      pref = NotificationPreference.for_user(recipient)
      pref.email_enabled && !pref.quiet_now?
    end

    def payload
      { id: id, status: status, attempt_count: attempt_count,
        sent_at: sent_at&.utc&.iso8601(6),
        next_retry_at: next_retry_at&.utc&.iso8601(6) }
    end

    private
      def same_tenant
        errors.add(:family, :invalid) unless
          recipient && inbox_notification && family_id == recipient.family_id &&
          inbox_notification.family_id == family_id &&
          inbox_notification.recipient_id == recipient_id
      end
  end
end
