module Abroa
  class RelationshipInvite < ApplicationRecord
    self.table_name = "abroa_relationship_invites"
    Conflict = Class.new(StandardError)
    LIFETIME = 7.days

    belongs_to :family
    belongs_to :inviter, class_name: "User"
    belongs_to :relationship, class_name: "Abroa::Relationship", optional: true

    validates :inviter_role, inclusion: { in: %w[parent student] }
    validates :status, inclusion: { in: %w[pending accepted rejected revoked expired] }
    validate :inviter_tenant

    def self.issue_for!(inviter, recipient_email:, recipient_role:, key:)
      raise ArgumentError, "Invalid invitation role" unless %w[parent student].include?(recipient_role)
      raise ArgumentError, "Invalid invitation key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      email = normalize_email!(recipient_email)
      role = recipient_role == "student" ? "parent" : "student"
      digest = Digest::SHA256.hexdigest(email)
      key_digest = Digest::SHA256.hexdigest(key)
      request_digest = Digest::SHA256.hexdigest("#{recipient_role}:#{email}")
      token = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "#{inviter.id}:#{key}")

      StudyProject.with_actor(inviter) do
        raise ActiveRecord::RecordNotFound unless Profile.for_user(inviter).public_send("#{role}_enabled?")
        raise ActiveRecord::RecordNotFound if email == inviter.email.downcase
        existing = find_by(inviter: inviter, creation_key_digest: key_digest)
        if existing
          raise Conflict, "Invitation key reused" unless existing.creation_request_digest == request_digest &&
            existing.inviter_role == role
          next [ existing, token ]
        end
        recipient = User.find_by(email: email)
        if recipient
          raise ActiveRecord::RecordNotFound if recipient.family_id == inviter.family_id
          student = role == "student" ? inviter : recipient
          parent = role == "parent" ? inviter : recipient
          if Relationship.exists?(student_user_id: student.id, parent_user_id: parent.id, status: "active")
            raise Conflict, "Relationship already exists"
          end
        end
        where(inviter: inviter, recipient_email_digest: digest, status: "pending")
          .where("expires_at <= ?", Time.current).update_all(status: "expired", updated_at: Time.current)
        if exists?(inviter: inviter, recipient_email_digest: digest, status: "pending")
          raise Conflict, "Invitation already pending"
        end

        invite = create!(family: inviter.family, inviter: inviter, inviter_role: role,
          recipient_email_digest: digest, token_digest: Digest::SHA256.hexdigest(token),
          creation_key_digest: key_digest, creation_request_digest: request_digest,
          status: "pending", expires_at: Time.current + LIFETIME)
        PlanningAuditEvent.record!(actor: inviter, event_type: "relationship_invite.issued", resource: invite)
        [ invite, token ]
      end
    end

    def self.accept_for!(recipient, token:)
      raise ActiveRecord::RecordNotFound unless token.is_a?(String) && token.match?(/\A[0-9a-f]{64}\z/)
      invite = find_by!(token_digest: Digest::SHA256.hexdigest(token))
      raise ActiveRecord::RecordNotFound unless recipient&.active? && !recipient.guest? &&
        Digest::SHA256.hexdigest(recipient.email.downcase.strip) == invite.recipient_email_digest
      # Both users are locked in a stable order, including competing invitations for the same pair.
      transaction do
        User.where(id: [ invite.inviter_id, recipient.id ]).order(:id).lock.load
        invite.lock!
        raise Conflict, "Invitation is not pending" unless invite.status == "pending"
        raise Conflict, "Invitation expired" if invite.expires_at <= Time.current
        inviter = invite.inviter
        raise ActiveRecord::RecordNotFound unless inviter.active? && inviter.family_id == invite.family_id
        student, parent = invite.inviter_role == "parent" ? [ recipient, inviter ] : [ inviter, recipient ]
        raise ActiveRecord::RecordNotFound if student.family_id == parent.family_id || student.id == parent.id
        raise ActiveRecord::RecordNotFound unless Profile.for_user(student).student_enabled? &&
          Profile.for_user(parent).parent_enabled?
        if Relationship.exists?(student_user_id: student.id, parent_user_id: parent.id, status: "active")
          raise Conflict, "Relationship already exists"
        end

        relation = Relationship.create!(family: student.family, student_family: student.family,
          parent_family: parent.family, student_user: student, parent_user: parent,
          accepted_at: Time.current, status: "active")
        invite.update!(status: "accepted", consumed_at: Time.current, relationship: relation)
        PlanningAuditEvent.record!(actor: recipient, event_type: "relationship_invite.accepted", resource: invite)
        PlanningAuditEvent.record!(actor: recipient, event_type: "relationship.activated", resource: relation)
        relation
      end
    end

    def self.reject_for!(recipient, token:)
      raise ActiveRecord::RecordNotFound unless token.is_a?(String) && token.match?(/\A[0-9a-f]{64}\z/)
      invite = find_by!(token_digest: Digest::SHA256.hexdigest(token))
      raise ActiveRecord::RecordNotFound unless recipient&.active? &&
        Digest::SHA256.hexdigest(recipient.email.downcase.strip) == invite.recipient_email_digest
      invite.with_lock do
        raise Conflict, "Invitation is not pending" unless invite.status == "pending" && invite.expires_at > Time.current
        invite.update!(status: "rejected", consumed_at: Time.current)
        PlanningAuditEvent.record!(actor: recipient, event_type: "relationship_invite.rejected", resource: invite)
        invite
      end
    end

    def self.revoke_for!(inviter, id:)
      StudyProject.with_actor(inviter) do
        invite = where(inviter: inviter).lock.find(id)
        raise Conflict, "Invitation is not pending" unless invite.status == "pending"
        invite.update!(status: "revoked", consumed_at: Time.current)
        PlanningAuditEvent.record!(actor: inviter, event_type: "relationship_invite.revoked", resource: invite)
        invite
      end
    end

    def self.for_actor(user)
      raise ActiveRecord::RecordNotFound unless user&.active?
      digest = Digest::SHA256.hexdigest(user.email.downcase.strip)
      where(inviter_id: user.id).or(where(recipient_email_digest: digest))
    end

    def self.normalize_email!(value)
      email = value.to_s.strip.downcase
      raise ArgumentError, "Invalid recipient email" unless email.bytesize.between?(3, 254) &&
        email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
      email
    end

    def payload
      attributes.slice("id", "inviter_id", "inviter_role", "status", "expires_at",
        "consumed_at", "relationship_id", "created_at").merge(
          "status" => status == "pending" && expires_at <= Time.current ? "expired" : status)
    end

    private
      def inviter_tenant
        errors.add(:family, :invalid) unless inviter && family_id == inviter.family_id
      end
  end
end
