module Abroa
  # Durable delivery-intent outbox. P4 notification channels can consume these
  # events without P2 sending unrequested mail or exposing account details.
  class FeeReminderEvent < ApplicationRecord
    self.table_name = "abroa_fee_reminder_events"
    belongs_to :family
    belongs_to :recipient, class_name: "User"
    belongs_to :fee_installment, class_name: "Abroa::FeeInstallment"

    validates :kind, inclusion: { in: %w[due_soon overdue] }
    validates :due_on, :occurred_at, presence: true
    validate :same_tenant

    def self.emit_for!(installment, recipient:, kind:)
      raise ArgumentError, "Unknown reminder event" unless %w[due_soon overdue].include?(kind)
      raise ActiveRecord::RecordNotFound unless installment.family_id == recipient.family_id
      create_or_find_by!(fee_installment: installment, kind: kind, due_on: installment.due_on) do |event|
        event.family = installment.family
        event.recipient = recipient
        event.occurred_at = Time.current
      end
    end

    def readonly?
      persisted? || super
    end

    private
      def same_tenant
        unless family && recipient && fee_installment &&
            family_id == recipient.family_id && family_id == fee_installment.family_id
          errors.add(:base, "Reminder event tenant mismatch")
        end
      end
  end
end
