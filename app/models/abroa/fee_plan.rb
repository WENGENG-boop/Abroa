module Abroa
  class FeePlan < ApplicationRecord
    self.table_name = "abroa_fee_plans"
    Conflict = Class.new(StandardError)
    KINDS = %w[tuition housing rent deposit visa insurance transport textbooks exam application other].freeze
    FIELDS = %i[name kind currency gross_amount discount_amount budget_node_id fund_pool_id
      recurring_transaction_id category_id].freeze

    belongs_to :family
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :budget_node, class_name: "Abroa::BudgetNode", optional: true
    belongs_to :fund_pool, class_name: "Abroa::FundPool", optional: true
    belongs_to :recurring_transaction, optional: true
    belongs_to :category, optional: true
    has_many :installments, class_name: "Abroa::FeeInstallment", foreign_key: :fee_plan_id
    has_many :adjustments, class_name: "Abroa::FeeAdjustment", foreign_key: :fee_plan_id

    validates :name, :kind, :currency, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: %w[active cancelled] }
    validate :valid_amounts_and_scope

    before_validation { self.currency = Decimal.currency!(currency) if currency.present? }

    def self.for_user(user)
      where(family_id: user.family_id, project_id: StudyProject.for_user(user).select(:id))
    end

    def self.create_for!(user, project_id, attributes:, key:)
      values = checked(attributes)
      raise ArgumentError, "Idempotency-Key required" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        digest = Digest::SHA256.hexdigest(key)
        request = Digest::SHA256.hexdigest(JSON.generate(values.deep_stringify_keys.sort.to_h))
        if (old = project.fee_plans.find_by(creation_key_digest: digest))
          raise Conflict, "Fee request changed" unless old.creation_request_digest == request
          next old
        end
        record = project.fee_plans.create!(values.merge(family: user.family,
          creation_key_digest: digest, creation_request_digest: request))
        PlanningAuditEvent.record!(actor: user, event_type: "fee_plan.created", resource: record)
        record
      end
    end

    def self.change_for!(user, id, version:, attributes:)
      values = checked(attributes)
      StudyProject.with_actor(user) do
        fee = for_user(user).lock.find(id)
        fee.project.ensure_writable!
        raise Conflict, "Fee changed" unless version.is_a?(Integer) && fee.lock_version == version
        raise Conflict, "Cancelled fee" if fee.status == "cancelled"
        # Even unpaid installments have established the fee's currency,
        # fund source and recurrence provenance. Changing them later would
        # silently relabel already scheduled contractual obligations.
        if (fee.installments.exists? || fee.adjustments.exists?) &&
            (values.keys & %i[currency kind fund_pool_id recurring_transaction_id]).any?
          raise Conflict, "Cannot change scheduled fee sources"
        end
        fee.update!(values)
        PlanningAuditEvent.record!(actor: user, event_type: "fee_plan.updated", resource: fee)
        fee
      end
    end

    def self.cancel_for!(user, id, version:)
      # As with pool consumption, take the same native-account advisory locks
      # before the family lock, so a concurrent Sure Goal update cannot deadlock.
      preflight = for_user(user).find(id)
      preflight_pool = preflight.fund_pool
      expected_accounts = if preflight_pool
        preflight_pool.movements.where(
          fee_installment_id: preflight.installments.select(:id)
        ).distinct.order(:account_id).pluck(:account_id)
      else
        []
      end
      ActiveRecord::Base.transaction do
        expected_accounts.each { |account_id| Goal.lock_whole_account_claims!(account_id) }
        StudyProject.with_actor(user) do
          fee = for_user(user).lock.find(id)
          fee.project.ensure_writable!
          raise Conflict, "Fee changed" unless version.is_a?(Integer) && fee.lock_version == version
          raise Conflict, "Settled fee cannot be cancelled" if fee.installments.joins(:settlements).exists?
          pool = fee.fund_pool
          if pool
            account_ids = pool.movements.where(fee_installment_id: fee.installments.select(:id))
              .distinct.order(:account_id).pluck(:account_id)
            raise Conflict, "Fee reserves changed during cancellation" unless account_ids == expected_accounts
            fee.installments.each do |installment|
              account_ids.each do |account_id|
                account = user.family.accounts.writable_by(user).find(account_id)
                reserved = PoolMovement.reserved_for_fee(pool, account, installment.id)
                next unless reserved.positive?
                PoolMovement.apply_for!(user, pool.id, account_id: account_id,
                  kind: "unreserve", amount: reserved.to_s("F"),
                  fee_installment_id: installment.id,
                  key: "fee-cancel:#{fee.id}:#{installment.id}:#{account_id}")
              end
            end
          end
          fee.update!(status: "cancelled")
          fee.installments.where.not(state: "cancelled").update_all(state: "cancelled", updated_at: Time.current)
          PlanningAuditEvent.record!(actor: user, event_type: "fee_plan.cancelled", resource: fee)
          fee
        end
      end
    end

    def self.checked(attributes)
      attrs = attributes.symbolize_keys
      raise ArgumentError, "Unknown fee field" unless (attrs.keys - FIELDS).empty?
      attrs
    end

    def amount_due
      approved = adjustments.where(status: "approved")
      gross_amount - discount_amount -
        approved.where(kind: %w[waiver scholarship_offset]).sum(:amount) +
        approved.where(kind: "surcharge").sum(:amount)
    end

    def paid_amount
      installments.reject { |i| i.state == "cancelled" }.sum(BigDecimal("0"), &:paid_amount)
    end

    def outstanding_amount
      return BigDecimal("0") if status == "cancelled"
      [ BigDecimal("0"), amount_due - paid_amount ].max
    end

    def refundable_deposit?
      kind == "deposit"
    end

    def payload_for(user)
      result = payload
      unless installments.all? { |item| item.readable_for?(user) }
        result[:paid_amount] = nil
        result[:outstanding_amount] = nil
        result[:incomplete] = true
      else
        result[:incomplete] = installments.any? { |item| item.settlements.any? { |entry| !entry.consistent? } }
      end
      result
    end

    def payload
      { id: id, project_id: project_id, name: name, kind: kind, currency: currency, status: status,
        gross_amount: gross_amount.to_s("F"), discount_amount: discount_amount.to_s("F"),
        amount_due: amount_due.to_s("F"), paid_amount: paid_amount.to_s("F"),
        outstanding_amount: outstanding_amount.to_s("F"), refundable_deposit: refundable_deposit?,
        budget_node_id: budget_node_id, fund_pool_id: fund_pool_id, recurring_transaction_id: recurring_transaction_id,
        category_id: category_id, lock_version: lock_version }
    end

    private
      def valid_amounts_and_scope
        begin
          gross = Decimal.money!(gross_amount, nonnegative: true)
          discount = Decimal.money!(discount_amount, nonnegative: true)
          errors.add(:discount_amount, :invalid) if discount > gross
        rescue ArgumentError
          errors.add(:base, "Invalid fee amounts")
        end
        errors.add(:project, :invalid) unless project && project.family_id == family_id
        errors.add(:budget_node, :invalid) if budget_node && budget_node.project_id != project_id
        errors.add(:fund_pool, :invalid) if fund_pool && fund_pool.project_id != project_id
        errors.add(:category, :invalid) if category && category.family_id != family_id
        if recurring_transaction &&
            (recurring_transaction.family_id != family_id ||
             recurring_transaction.account_id.nil? ||
             !project&.owner ||
             !project.owner.family.accounts.accessible_by(project.owner)
               .where(id: recurring_transaction.account_id).exists?)
          errors.add(:recurring_transaction, :invalid)
        end
        return unless persisted?
        if installments.where.not(state: "cancelled").to_a.sum(BigDecimal("0"), &:net_amount) > amount_due
          errors.add(:base, "Installments exceed discounted fee amount")
        end
      end
  end
end
