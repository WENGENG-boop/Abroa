class Abroa::GovernanceRequest < ApplicationRecord
  self.table_name = "abroa_governance_requests"

  KINDS = %w[export deletion].freeze
  STATES = %w[requested approved processing completed rejected failed].freeze
  TRANSITIONS = {
    "requested" => %w[approved rejected],
    "approved" => %w[processing rejected],
    "processing" => %w[completed failed],
    "failed" => %w[approved rejected],
    "rejected" => [],
    "completed" => []
  }.freeze
  Conflict = Class.new(StandardError)
  Forbidden = Class.new(StandardError)

  validates :user_id, :requested_at, :request_id, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATES }
  validates :request_id, uniqueness: { scope: :user_id }
  validates :reason_code, inclusion: {
    in: %w[user_request validated_export completed_erasure provider_delay invalid_request],
    allow_nil: true
  }

  def self.request_for!(user:, kind:, request_id:)
    raise Forbidden unless user&.active? && !user.guest?
    raise ArgumentError, "Invalid governance kind" unless KINDS.include?(kind)
    raise ArgumentError, "Invalid request ID" unless request_id.is_a?(String) &&
      request_id.bytesize.between?(1, 128)

    transaction do
      user.lock!
      raise Forbidden unless user.active?
      existing = find_by(user_id: user.id, request_id: request_id)
      if existing
        raise Conflict, "Request ID was reused for a different purpose" unless existing.kind == kind
        next existing
      end

      create!(user_id: user.id, kind: kind, status: "requested",
        requested_at: Time.current, request_id: request_id)
    end
  end

  def transition!(actor:, status:, version:, evidence_export_id: nil, reason_code: nil)
    raise Forbidden unless Abroa::PlatformRoleAssignment.permitted?(actor, "operations.write")
    raise ArgumentError, "Invalid governance status" unless STATES.include?(status)
    raise ArgumentError, "Version required" unless version.is_a?(Integer) && version >= 0

    with_lock do
      raise Conflict, "Governance request version changed" unless lock_version == version
      raise Conflict, "Invalid governance state transition" unless TRANSITIONS.fetch(self.status).include?(status)

      if status == "completed"
        raise Conflict, "Completion requires processing state and verified evidence" unless
          completion_evidence_verified?(evidence_export_id)
      end

      self.status = status
      self.reason_code = reason_code if reason_code.present?
      self.reviewed_by_id = actor.id
      self.reviewed_at = Time.current
      self.completed_at = Time.current if status == "completed"
      self.evidence_export_id = evidence_export_id if status == "completed" && kind == "export"
      save!

      Abroa::PlatformAuditEvent.create!(
        actor_user_id: actor.id, target_user_id: user_id,
        action: "governance_transition", outcome: "transitioned",
        request_id: SecureRandom.uuid, occurred_at: Time.current,
        safe_changes: { "request_id" => id, "status" => status,
          "version" => lock_version, "kind" => kind }
      )
      self
    end
  end

  def payload
    {
      id: id, kind: kind, status: status, requested_at: requested_at,
      reviewed_at: reviewed_at, completed_at: completed_at,
      version: lock_version
    }
  end

  private

    def completion_evidence_verified?(export_id)
      if kind == "export"
        user = User.find_by(id: user_id)
        return false unless user && export_id.to_s.match?(
          /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
        )
        proof = FamilyExport.find_by(id: export_id, family_id: user.family_id, status: "completed")
        proof&.downloadable? || false
      else
        # Never delete an account from the admin API. The user's own
        # authenticated deletion/export workflow must complete independently.
        !User.exists?(id: user_id)
      end
    end
end
