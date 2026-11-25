module Abroa
  # A non-sensitive notification pointer; source permissions are always
  # checked anew for API reads and email sending.
  class InboxNotification < ApplicationRecord
    self.table_name = "abroa_inbox_notifications"
    Conflict = Class.new(StandardError)
    KINDS = %w[fee_due fee_overdue budget_risk cash_shortfall transaction_review
      funding invitation grant_change sync_failed debt_due general].freeze

    belongs_to :family
    belongs_to :recipient, class_name: "User"
    has_one :email_outbox, class_name: "Abroa::EmailOutbox", dependent: :restrict_with_exception

    validates :event_kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: %w[unread read] }
    validates :source_type, :source_id, :event_key_digest, :occurred_at, presence: true
    validate :valid_recipient_scope

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      where(recipient_id: user.id, family_id: user.family_id)
    end

    def self.emit_for!(recipient:, event_kind:, source:, event_key:)
      raise ArgumentError, "Invalid notification event kind" unless KINDS.include?(event_kind)
      unless event_key.is_a?(String) && event_key.bytesize.between?(1, 200) &&
          event_key.match?(/\A[[:graph:]]+\z/)
        raise ArgumentError, "Invalid stable notification key"
      end
      raise ActiveRecord::RecordNotFound unless recipient&.active? && !recipient.guest?
      raise ActiveRecord::RecordNotFound unless authorized_source?(recipient, source)
      pref = NotificationPreference.for_user(recipient)
      return nil unless pref.in_app_enabled || pref.email_enabled
      digest = Digest::SHA256.hexdigest(event_key)
      transaction do
        item = create_or_find_by!(recipient_id: recipient.id, event_key_digest: digest) do |record|
          record.family = recipient.family
          record.event_kind = event_kind
          record.source_type = source.class.name
          record.source_id = source.id
          record.occurred_at = Time.current
        end
        unless item.event_kind == event_kind && item.source_type == source.class.name &&
            item.source_id == source.id && item.family_id == recipient.family_id
          raise Conflict, "Stable event key reused for another source"
        end
        if pref.email_enabled
          EmailOutbox.create_or_find_by!(inbox_notification_id: item.id) do |row|
            row.family = recipient.family
            row.recipient = recipient
            row.status = "pending"
          end
        end
        item
      end
    end

    def self.authorized_source?(user, source)
      return false unless user&.active? && !user.guest? && source&.persisted?
      case source
      when Entry
        source.account&.family_id == user.family_id &&
          AccountPolicy.new(user, source.account).show?
      when Account
        source.family_id == user.family_id && AccountPolicy.new(user, source).show?
      when BudgetNode
        (source.family_id == user.family_id && source.project&.owner_id == user.id) ||
          (source.project && Grant.allowed?(user, source.project, "budget_read",
            resource_kind: "budget_node", resource_id: source.id))
      when FeePlan
        (source.family_id == user.family_id && source.project&.owner_id == user.id) ||
          (source.project && Grant.allowed?(user, source.project, "fees_read"))
      when StudyProject
        (source.owner_id == user.id && source.family_id == user.family_id) ||
          Grant.allowed?(user, source, "summary")
      when FeeReminderEvent
        source.recipient_id == user.id && source.family_id == user.family_id &&
          source.fee_installment&.fee_plan&.project&.owner_id == user.id &&
          source.fee_installment.readable_for?(user)
      when FundingPlan
        (source.student_user_id == user.id && source.family_id == user.family_id) ||
          (source.parent_user_id == user.id && source.relationship&.active_for?(user) &&
            source.relationship.parent_family_id == user.family_id)
      when Relationship
        (source.student_user_id == user.id && source.student_family_id == user.family_id) ||
          (source.parent_user_id == user.id && source.parent_family_id == user.family_id)
      when RelationshipInvite
        (source.inviter_id == user.id && source.family_id == user.family_id) ||
          (source.recipient_email_digest == Digest::SHA256.hexdigest(user.email.downcase.strip) &&
            source.status.in?(%w[pending accepted rejected revoked expired]))
      when Grant
        (source.actor_id == user.id && source.family_id == user.family_id) ||
          (source.relationship&.parent_user_id == user.id &&
            source.relationship&.parent_family_id == user.family_id &&
            source.relationship&.status == "active")
      else
        false
      end
    end

    def authorized_for?(viewer)
      viewer && viewer.id == recipient_id && viewer.family_id == family_id &&
        self.class.authorized_source?(viewer, source_record)
    end

    def source_record
      source_class = {
        "Entry" => Entry,
        "Account" => Account,
        "Abroa::BudgetNode" => BudgetNode,
        "Abroa::FeePlan" => FeePlan,
        "Abroa::StudyProject" => StudyProject,
        "Abroa::FeeReminderEvent" => FeeReminderEvent,
        "Abroa::FundingPlan" => FundingPlan,
        "Abroa::Relationship" => Relationship,
        "Abroa::RelationshipInvite" => RelationshipInvite,
        "Abroa::Grant" => Grant
      }[source_type]
      source_class&.find_by(id: source_id)
    end

    def mark_read_for!(viewer)
      with_lock do
        raise ActiveRecord::RecordNotFound unless authorized_for?(viewer) &&
          NotificationPreference.for_user(viewer).in_app_enabled
        update!(read_at: Time.current, state: "read") if state == "unread"
        self
      end
    end

    def payload
      { id: id, event_kind: event_kind, state: state,
        occurred_at: occurred_at.utc.iso8601(6), read_at: read_at&.utc&.iso8601(6) }
    end

    private
      def valid_recipient_scope
        errors.add(:family, :invalid) unless recipient && family_id == recipient.family_id
      end
  end
end
