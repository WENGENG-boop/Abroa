module Abroa
  # Expected parental support. This model NEVER writes an Account balance, Entry or Transaction.
  # Only FundingReceipt may reference a separately confirmed Sure ledger inflow.
  class FundingPlan < ApplicationRecord
    self.table_name = "abroa_funding_plans"
    Conflict = Class.new(StandardError)
    FREQUENCIES = %w[once weekly monthly quarterly yearly].freeze
    KINDS = %w[living tuition housing rent travel emergency other].freeze
    FIELDS = %i[name kind amount currency frequency scheduled_on ends_on source_account_id fund_pool_id].freeze
    MAX_OCCURRENCES = 120

    belongs_to :family
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :relationship, class_name: "Abroa::Relationship"
    belongs_to :student_user, class_name: "User"
    belongs_to :parent_user, class_name: "User"
    belongs_to :created_by, class_name: "User"
    belongs_to :source_account, class_name: "Account", optional: true
    belongs_to :destination_account, class_name: "Account", optional: true
    belongs_to :fund_pool, class_name: "Abroa::FundPool", optional: true
    has_many :receipts, class_name: "Abroa::FundingReceipt", dependent: :restrict_with_exception
    has_many :notices, class_name: "Abroa::FundingNotice", dependent: :restrict_with_exception

    validates :name, presence: true, length: { maximum: 255 }
    validates :kind, inclusion: { in: KINDS }
    validates :frequency, inclusion: { in: FREQUENCIES }
    validates :status, inclusion: { in: %w[planned confirmed partially_received received cancelled rejected] }
    validates :scheduled_on, :currency, :amount, presence: true
    validate :valid_tenant_and_references
    validate :valid_schedule_amount
    before_validation { self.currency = Decimal.currency!(currency) if currency.present? }

    def self.for_actor(user)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      parent_links = Relationship.where(parent_user_id: user.id,
        parent_family_id: user.family_id, status: "active").select(:id)
      where(student_user_id: user.id, family_id: user.family_id).or(
        where(parent_user_id: user.id, relationship_id: parent_links))
    end

    def self.for_student(user)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      where(student_user_id: user.id, family_id: user.family_id)
    end

    def self.create_for!(parent, relationship_id:, project_id:, attributes:, key:)
      fields = checked(attributes)
      raise ArgumentError, "Idempotency-Key invalid" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      request = Digest::SHA256.hexdigest(JSON.generate({
        relationship_id: relationship_id, project_id: project_id, attributes: fields
      }.deep_stringify_keys.sort.to_h))
      digest = Digest::SHA256.hexdigest(key)
      StudyProject.with_actor(parent) do
        raise ActiveRecord::RecordNotFound unless Profile.for_user(parent).parent_enabled?
        old = where(created_by_id: parent.id, creation_key_digest: digest).first
        if old
          raise Conflict, "Funding request changed" unless old.creation_request_digest == request
          next old
        end
        relation = Relationship.where(id: relationship_id, parent_user_id: parent.id,
          parent_family_id: parent.family_id, status: "active").lock.first!
        project = StudyProject.where(id: project_id, owner_id: relation.student_user_id,
          family_id: relation.student_family_id).first!
        project.ensure_writable!
        if fields[:source_account_id]
          own = parent.family.accounts.writable_by(parent).find(fields[:source_account_id])
          raise ActiveRecord::RecordNotFound unless AccountPolicy.new(parent, own).permits?(:write)
        end
        if fields[:fund_pool_id]
          pool = FundPool.where(id: fields[:fund_pool_id], project_id: project.id,
            family_id: project.family_id, status: "active").first!
          raise ActiveRecord::RecordNotFound unless Grant.allowed?(parent, project, "pool_manage",
            resource_kind: "fund_pool", resource_id: pool.id)
        end
        record = create!(fields.merge(family: project.family, project: project, relationship: relation,
          student_user: relation.student_user, parent_user: parent, created_by: parent,
          creation_key_digest: digest, creation_request_digest: request))
        PlanningAuditEvent.record!(actor: parent, event_type: "funding_plan.created", resource: record,
          safe_data: { project_id: project.id, currency: record.currency, planned_amount: record.planned_total.to_s("F") })
        record
      end
    end

    def self.change_for!(parent, id, version:, attributes:)
      fields = checked(attributes)
      StudyProject.with_actor(parent) do
        plan = where(parent_user_id: parent.id, created_by_id: parent.id).lock.find(id)
        raise Conflict, "Funding plan changed" unless version.is_a?(Integer) && version == plan.lock_version
        raise Conflict, "Confirmed funding cannot be changed" unless plan.status == "planned"
        raise ActiveRecord::RecordNotFound unless plan.relationship.status == "active" &&
          plan.relationship.parent_family_id == parent.family_id
        plan.project.ensure_writable!
        if fields.key?(:fund_pool_id) && fields[:fund_pool_id]
          pool = FundPool.where(id: fields[:fund_pool_id], family_id: plan.family_id,
            project_id: plan.project_id).first!
          raise ActiveRecord::RecordNotFound unless Grant.allowed?(parent, plan.project, "pool_manage",
            resource_kind: "fund_pool", resource_id: pool.id)
        end
        if fields.key?(:source_account_id) && fields[:source_account_id]
          parent.family.accounts.writable_by(parent).find(fields[:source_account_id])
        end
        plan.update!(fields)
        PlanningAuditEvent.record!(actor: parent, event_type: "funding_plan.updated", resource: plan)
        plan
      end
    end

    def self.confirm_for!(student, id, version:, destination_account_id:, fund_pool_id: nil)
      StudyProject.with_actor(student) do
        plan = for_student(student).lock.find(id)
        raise Conflict, "Funding plan changed" unless version.is_a?(Integer) && version == plan.lock_version
        raise Conflict, "Plan is not pending confirmation" unless plan.status == "planned"
        raise Conflict, "Parent relationship revoked" unless plan.relationship.status == "active" &&
          plan.relationship.student_user_id == student.id
        plan.project.ensure_writable!
        account = student.family.accounts.writable_by(student).find(destination_account_id)
        raise ActiveRecord::RecordNotFound unless AccountPolicy.new(student, account).permits?(:write)
        if fund_pool_id
          pool = FundPool.for_user(student).where(project_id: plan.project_id, status: "active").find(fund_pool_id)
          plan.fund_pool = pool
        end
        plan.update!(status: "confirmed", confirmed_at: Time.current, destination_account: account)
        PlanningAuditEvent.record!(actor: student, event_type: "funding_plan.confirmed", resource: plan)
        plan
      end
    end

    def self.reject_for!(student, id, version:)
      StudyProject.with_actor(student) do
        plan = for_student(student).lock.find(id)
        raise Conflict, "Funding plan changed" unless version.is_a?(Integer) && plan.lock_version == version
        raise Conflict, "Only unconfirmed plans can be rejected" unless plan.status == "planned"
        plan.update!(status: "rejected", cancelled_at: Time.current)
        PlanningAuditEvent.record!(actor: student, event_type: "funding_plan.rejected", resource: plan)
        plan
      end
    end

    def self.cancel_for!(actor, id, version:)
      plan = for_actor(actor).find(id)
      student = plan.student_user
      StudyProject.with_actor(student) do
        plan = for_actor(actor).lock.find(id)
        raise Conflict, "Funding plan changed" unless version.is_a?(Integer) && plan.lock_version == version
        raise Conflict, "Plan not cancellable" if %w[cancelled rejected received].include?(plan.status)
        if actor.id == plan.parent_user_id && plan.relationship.status != "active"
          raise ActiveRecord::RecordNotFound
        end
        plan.update!(status: "cancelled", cancelled_at: Time.current)
        PlanningAuditEvent.record!(actor: actor, event_type: "funding_plan.cancelled", resource: plan)
        plan
      end
    end

    def self.checked(attributes)
      fields = attributes.to_h.symbolize_keys
      raise ArgumentError, "Unknown funding field" unless (fields.keys - FIELDS).empty?
      fields
    end

    def schedule_dates
      return [] unless scheduled_on && FREQUENCIES.include?(frequency)
      return [ scheduled_on ] if frequency == "once"
      return [] unless ends_on && ends_on >= scheduled_on
      dates = []
      idx = 0
      loop do
        day = case frequency
        when "weekly" then scheduled_on + idx * 7.days
        when "monthly" then scheduled_on >> idx
        when "quarterly" then scheduled_on >> (idx * 3)
        when "yearly" then scheduled_on >> (idx * 12)
        end
        break if day > ends_on
        dates << day
        raise ArgumentError, "Funding schedule exceeds occurrence limit" if dates.size > MAX_OCCURRENCES
        idx += 1
      end
      dates
    end

    def planned_total
      return BigDecimal("0") unless amount
      amount * schedule_dates.size
    end

    def evidence_consistent?
      receipts.all? { |receipt| receipt.consistent? && receipt.reversals.all?(&:consistent?) }
    end

    def received_total
      raise Conflict, "Matched ledger or refund evidence changed" unless evidence_consistent?
      gross = receipts.sum(:applied_amount)
      returned = FundingReversal.where(funding_receipt_id: receipts.select(:id)).sum(:applied_amount)
      result = gross - returned
      raise Conflict, "Funding receipts do not conserve amount" if result.negative?
      result
    end

    def outstanding_total
      return BigDecimal("0") if %w[cancelled rejected].include?(status)
      [ planned_total - received_total, BigDecimal("0") ].max
    end

    def reported_sent_total
      notices.where(status: "active").sum(:amount)
    end

    def pending_match_total
      [ reported_sent_total - received_total, BigDecimal("0") ].max
    end

    def refresh_after_receipt!
      return self if %w[cancelled rejected].include?(status)
      amount_received = received_total
      target_status = if amount_received >= planned_total
        "received"
      elsif amount_received.positive?
        "partially_received"
      else
        "confirmed"
      end
      update!(status: target_status) if status != target_status
      self
    end

    def payload_for(viewer)
      raise ActiveRecord::RecordNotFound unless viewer&.active? &&
        (viewer.id == student_user_id || viewer.id == parent_user_id)
      own_student = viewer.id == student_user_id && viewer.family_id == family_id
      own_parent = viewer.id == parent_user_id && viewer.family_id == relationship.parent_family_id
      raise ActiveRecord::RecordNotFound unless own_student || (own_parent && relationship.status == "active")
      info = { id: id, project_id: project_id, name: name, kind: kind,
        amount: amount.to_s("F"), currency: currency, frequency: frequency,
        scheduled_on: scheduled_on.iso8601, ends_on: ends_on&.iso8601,
        planned_amount: planned_total.to_s("F"), status: status, lock_version: lock_version }
      if own_student || (own_parent && relationship.status == "active")
        if evidence_consistent?
          info.merge!(received_amount: received_total.to_s("F"),
            outstanding_amount: outstanding_total.to_s("F"),
            pending_matching_amount: pending_match_total.to_s("F"), incomplete: false)
        else
          info.merge!(received_amount: nil, outstanding_amount: nil,
            pending_matching_amount: nil, incomplete: true)
        end
      end
      info[:source_account_id] = source_account_id if own_parent
      if own_student
        info[:destination_account_id] = destination_account_id
        info[:fund_pool_id] = fund_pool_id
      elsif own_parent && relationship.status == "active" && fund_pool_id &&
          Grant.allowed?(viewer, project, "pool_manage", resource_kind: "fund_pool", resource_id: fund_pool_id)
        info[:fund_pool_id] = fund_pool_id
      end
      info
    end

    private
      def valid_tenant_and_references
        return unless project && relationship && student_user && parent_user && created_by
        errors.add(:family, :invalid) unless family_id == project.family_id &&
          family_id == relationship.student_family_id &&
          student_user_id == project.owner_id && student_user_id == relationship.student_user_id &&
          parent_user_id == relationship.parent_user_id &&
          parent_user.family_id == relationship.parent_family_id &&
          [ student_user_id, parent_user_id ].include?(created_by_id)
        errors.add(:source_account, :invalid) if source_account &&
          source_account.family_id != parent_user.family_id
        errors.add(:destination_account, :invalid) if destination_account &&
          destination_account.family_id != student_user.family_id
        errors.add(:fund_pool, :invalid) if fund_pool &&
          (fund_pool.project_id != project_id || fund_pool.family_id != family_id)
      end

      def valid_schedule_amount
        begin
          Decimal.money!(amount, positive: true)
          Decimal.currency!(currency)
        rescue ArgumentError
          errors.add(:amount, :invalid)
        end
        unless scheduled_on && (frequency == "once" && ends_on.nil? ||
            frequency != "once" && ends_on && ends_on >= scheduled_on) &&
            project && scheduled_on >= project.start_on &&
            (!project.end_on || (ends_on || scheduled_on) <= project.end_on)
          errors.add(:scheduled_on, :invalid)
          return
        end
        begin
          errors.add(:ends_on, "Schedule must include at most 120 occurrences") if schedule_dates.size > MAX_OCCURRENCES
        rescue ArgumentError
          errors.add(:ends_on, :invalid)
        end
      end
  end
end
