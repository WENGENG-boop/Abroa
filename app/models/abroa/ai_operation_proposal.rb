require "securerandom"

module Abroa
  # Human-approved AI command: the model never receives a write tool or a
  # confirmation token. Operations call only pre-existing P2 domain services.
  class AiOperationProposal < ApplicationRecord
    self.table_name = "abroa_ai_operation_proposals"
    Conflict = Class.new(StandardError)
    EXECUTABLE = AiProposalAdapter::EXECUTABLE
    MAX_AGE = 15.minutes

    belongs_to :family
    belongs_to :owner, class_name: "User"
    belongs_to :project, class_name: "Abroa::StudyProject", optional: true
    validates :operation, inclusion: { in: EXECUTABLE }
    validates :status, inclusion: { in: %w[proposed confirmed executed rejected compensated cancelled] }
    validate :valid_tenant

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      where(owner_id: user.id, family_id: user.family_id)
    end

    def self.propose_for!(user, operation:, resource_id:, parameters:, key:)
      raise ArgumentError, "Unsupported AI operation" unless EXECUTABLE.include?(operation)
      raise ArgumentError, "Invalid idempotency key" unless key.is_a?(String) &&
        key.bytesize.between?(1, 128)
      params = parameters.to_h.deep_stringify_keys
      with_financial_actor(user, operation, params) do
        prepared = AiProposalAdapter.prepare!(user, operation: operation,
          resource_id: resource_id, parameters: params)
        resource = prepared.fetch(:resource)
        normalized = prepared.fetch(:parameters)
        digest = Digest::SHA256.hexdigest(key)
        request = Digest::SHA256.hexdigest([ operation, resource.id, normalized ].to_json)
        old = for_user(user).find_by(creation_key_digest: digest)
        if old
          raise Conflict, "Proposal key reused" unless old.creation_request_digest == request
          # Replaying a request never reissues a plaintext confirmation token.
          next [ old, nil ]
        end
        resource.lock!
        raise Conflict, "Resource changed during proposal" unless
          prepared[:state_digest] == AiProposalAdapter.state_digest(user, resource, operation, normalized)
        token = SecureRandom.urlsafe_base64(32)
        record = create!(family: user.family, owner: user, project: resource.project,
          operation: operation, resource_type: resource.class.name, resource_id: resource.id,
          parameters: normalized, before_snapshot: prepared.fetch(:before),
          expected_resource_version: resource.lock_version,
          expected_state_digest: prepared.fetch(:state_digest),
          confirmation_digest: Digest::SHA256.hexdigest(token),
          creation_key_digest: digest, creation_request_digest: request,
          status: "proposed", expires_at: MAX_AGE.from_now)
        PlanningAuditEvent.record!(actor: user, event_type: "ai_proposal.created",
          resource: record, safe_data: { operation: operation, project_id: resource.project_id })
        [ record, token ]
      end
    end

    def self.confirm_for!(user, id, token:, version:)
      with_existing_proposal(user, id) do |proposal|
        raise Conflict, "Proposal expired or not pending" unless
          proposal.status == "proposed" && proposal.expires_at > Time.current
        raise Conflict, "Proposal version changed" unless version.is_a?(Integer) &&
          proposal.lock_version == version
        raise Conflict, "Invalid confirmation token" unless token.is_a?(String) &&
          token.bytesize.between?(32, 100) &&
          ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(token),
            proposal.confirmation_digest)
        verify_target!(user, proposal)
        proposal.update!(status: "confirmed", confirmed_at: Time.current)
        PlanningAuditEvent.record!(actor: user, event_type: "ai_proposal.confirmed", resource: proposal)
        proposal
      end
    end

    def self.execute_for!(user, id)
      with_existing_proposal(user, id) do |proposal|
        next proposal if proposal.status == "executed"
        raise Conflict, "Separate, current confirmation required" unless
          proposal.status == "confirmed" && proposal.confirmed_at &&
          proposal.expires_at > Time.current
        target = verify_target!(user, proposal)
        execution = AiProposalAdapter.execute!(user, proposal, target)
        proposal.update!(status: "executed", executed_at: Time.current,
          execution_resource_id: execution.fetch(:execution_id),
          execution_resource_version: execution.fetch(:resource_version),
          execution_state_digest: execution.fetch(:state_digest))
        PlanningAuditEvent.record!(actor: user, event_type: "ai_proposal.executed", resource: proposal,
          safe_data: { operation: proposal.operation, resource_id: proposal.resource_id })
        proposal
      end
    end

    def self.compensate_for!(user, id)
      with_existing_proposal(user, id) do |proposal|
        next proposal if proposal.status == "compensated"
        raise Conflict, "Only executed proposals can be compensated" unless
          proposal.status == "executed" && EXECUTABLE.include?(proposal.operation)
        target = AiProposalAdapter.resource_for!(user, proposal.operation, proposal.resource_id)
        target.lock!
        target.project.ensure_writable!
        raise Conflict, "Resource changed after AI action" unless
          target.project_id == proposal.project_id &&
          target.lock_version == proposal.execution_resource_version &&
          AiProposalAdapter.state_digest(user, target, proposal.operation,
            proposal.parameters) == proposal.execution_state_digest
        AiProposalAdapter.compensate!(user, proposal, target)
        proposal.update!(status: "compensated", compensated_at: Time.current)
        PlanningAuditEvent.record!(actor: user, event_type: "ai_proposal.compensated",
          resource: proposal, safe_data: { operation: proposal.operation })
        proposal
      end
    end

    def reject_for!(actor)
      self.class.with_existing_proposal(actor, id) do |proposal|
        raise Conflict, "Cannot reject after confirmation" unless proposal.status == "proposed"
        proposal.update!(status: "rejected")
        PlanningAuditEvent.record!(actor: actor, event_type: "ai_proposal.rejected", resource: proposal)
        proposal
      end
    end

    def payload
      { id: id, operation: operation, project_id: project_id,
        resource_type: resource_type, resource_id: resource_id,
        parameters: parameters, before_snapshot: before_snapshot, status: status,
        expected_resource_version: expected_resource_version, lock_version: lock_version,
        expires_at: expires_at.utc.iso8601(6), confirmed_at: confirmed_at&.utc&.iso8601(6),
        executed_at: executed_at&.utc&.iso8601(6) }
    end

    def self.with_existing_proposal(user, id)
      raise ActiveRecord::RecordNotFound unless UuidFormat.valid?(id)
      record = for_user(user).find(id)
      with_financial_actor(user, record.operation, record.parameters) do
        current = for_user(user).lock.find(id)
        yield current
      end
    end

    def self.verify_target!(user, proposal)
      target = AiProposalAdapter.resource_for!(user, proposal.operation, proposal.resource_id)
      target.lock!
      target.project.ensure_writable!
      raise Conflict, "Resource or evidence changed" unless
        target.project_id == proposal.project_id &&
        target.lock_version == proposal.expected_resource_version &&
        AiProposalAdapter.state_digest(user, target, proposal.operation,
          proposal.parameters) == proposal.expected_state_digest
      target
    end

    def self.with_financial_actor(user, operation, params)
      if operation == "pool_allocate"
        account_id = params["account_id"] || params[:account_id]
        raise ActiveRecord::RecordNotFound unless UuidFormat.valid?(account_id)
        # P2 contract requires Goal advisory lock before family row lock.
        ActiveRecord::Base.transaction do
          Goal.lock_whole_account_claims!(account_id)
          StudyProject.with_actor(user) { yield }
        end
      else
        StudyProject.with_actor(user) { yield }
      end
    end

    private
      def valid_tenant
        errors.add(:family, :invalid) unless owner && family && owner.family_id == family_id &&
          project && project.family_id == family_id && project.owner_id == owner_id
      end
  end
end
