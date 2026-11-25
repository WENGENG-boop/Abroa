module Abroa
  class BudgetNode < ApplicationRecord
    self.table_name = "abroa_budget_nodes"
    Conflict = Class.new(StandardError)
    FIELDS = %i[name start_on end_on currency limit_amount parent_id period_id category_id sure_budget_id
      rollover_enabled warning_threshold status].freeze
    STATUSES = %w[active closed archived].freeze

    belongs_to :family
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :parent, class_name: "Abroa::BudgetNode", optional: true
    belongs_to :period, class_name: "Abroa::StudyPeriod", optional: true
    belongs_to :category, optional: true
    belongs_to :sure_budget, class_name: "Budget", optional: true
    belongs_to :rollover_target, class_name: "Abroa::BudgetNode", optional: true
    has_many :children, class_name: "Abroa::BudgetNode", foreign_key: :parent_id
    has_many :versions, class_name: "Abroa::BudgetVersion", foreign_key: :budget_node_id

    validates :name, :start_on, :end_on, :currency, :limit_amount, presence: true
    validates :status, inclusion: { in: STATUSES }
    validate :valid_hierarchy
    validate :valid_monetary_fields

    before_validation do
      self.currency = Decimal.currency!(currency) if currency.present?
    end

    def self.create_for!(user, project_id, attributes:, key: nil)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        fields = checked(attributes)
        writer = lambda do
          record = project.budget_nodes.create!(fields.merge(family: user.family))
          record.version_for!(user, kind: "created", before: {})
          PlanningAuditEvent.record!(actor: user, event_type: "budget.created", resource: record)
          record
        end
        key ? OperationRecord.perform!(actor: user, operation: "budget.create:#{project.id}",
          key: key, payload: fields, &writer) : writer.call
      end
    end

    def self.change_for!(user, id, version:, attributes:)
      StudyProject.with_actor(user) do
        node = for_user(user).lock.find(id)
        raise Conflict, "Budget version changed" unless version.is_a?(Integer) && node.lock_version == version
        node.project.ensure_writable!
        raise Conflict, "Budget is not active" unless node.status == "active" || checked(attributes).keys == [ :status ]
        before = node.version_data
        node.update!(checked(attributes))
        node.version_for!(user, kind: "adjusted", before: before)
        PlanningAuditEvent.record!(actor: user, event_type: "budget.adjusted", resource: node)
        node
      end
    end

    def self.parent_change_for!(parent, id, version:, attributes:)
      fields = checked(attributes)
      raise ArgumentError, "Direct budget edit only permits bounded fields" unless
        (fields.keys - %i[name limit_amount warning_threshold]).empty? && fields.any?
      raise ActiveRecord::RecordNotFound unless parent&.active? && !parent.guest? &&
        Profile.for_user(parent).parent_enabled?
      # Discover an authorized student through the grant, not the private budget table.
      candidate = Grant.scoped_to_parent(parent, capability: "budget_manage")
        .where("abroa_grants.project_id IN (SELECT project_id FROM abroa_budget_nodes WHERE id = ?)", id)
        .where("(abroa_grants.resource_kind = 'project' AND abroa_grants.resource_id IS NULL) OR
          (abroa_grants.resource_kind = 'budget_node' AND abroa_grants.resource_id = ?)", id).first!
      student = candidate.relationship.student_user
      StudyProject.with_actor(student) do
        grant = Grant.scoped_to_parent(parent, capability: "budget_manage").where(id: candidate.id)
          .where("abroa_grants.project_id IN (SELECT project_id FROM abroa_budget_nodes WHERE id = ?)", id)
          .where("(abroa_grants.resource_kind = 'project' AND abroa_grants.resource_id IS NULL) OR
            (abroa_grants.resource_kind = 'budget_node' AND abroa_grants.resource_id = ?)", id).lock.first!
        node = where(id: id, family_id: grant.family_id, project_id: grant.project_id).lock.first!
        raise Conflict, "Budget changed" unless version.is_a?(Integer) && node.lock_version == version
        raise Conflict, "Budget not editable" unless node.status == "active"
        node.project.ensure_writable!
        before = node.version_data
        node.update!(fields)
        node.versions.create!(family: node.family, actor: parent, kind: "parent_direct",
          from_data: before, to_data: node.version_data)
        PlanningAuditEvent.record!(actor: parent, event_type: "budget.parent_direct", resource: node,
          safe_data: { project_id: node.project_id })
        node
      end
    end

    def self.for_user(user)
      StudyProject.for_user(user)
      where(project_id: StudyProject.for_user(user).select(:id), family_id: user.family_id)
    end

    def self.rollover_for!(user, source_id, target_id:, key:)
      raise ArgumentError, "Invalid rollover key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      StudyProject.with_actor(user) do
        nodes = for_user(user).where(id: [ source_id, target_id ]).order(:id).lock.index_by(&:id)
        source = nodes.fetch(source_id) { raise ActiveRecord::RecordNotFound }
        target = nodes.fetch(target_id) { raise ActiveRecord::RecordNotFound }
        if source.rollover_target_id.present?
          raise Conflict, "Rollover already applied to a different node" unless source.rollover_target_id == target.id &&
            BudgetVersion.where(family_id: user.family_id, budget_node_id: target.id, operation_key: key).exists?
          next target
        end
        unless source.status == "closed" && source.rollover_enabled? && target.status == "active" &&
            target.rollover_enabled? && source.project_id == target.project_id &&
            source.currency == target.currency && source.category_id == target.category_id &&
            source.end_on < target.start_on && source.parent_id == target.parent_id
          raise ArgumentError, "Budget periods or scope are incompatible for rollover"
        end
        source.project.ensure_writable!
        execution = source.execution_for!(user)
        raise Conflict, "Cannot roll over incomplete budget" if execution[:incomplete]
        carry = [ BigDecimal("0"), execution[:remaining] ].max
        before = target.version_data
        target.update!(rollover_amount: target.rollover_amount + carry)
        source.update!(rollover_target: target)
        target.version_for!(user, kind: "rollover", before: before, key: key)
        PlanningAuditEvent.record!(actor: user, event_type: "budget.rolled_over", resource: target,
          safe_data: { source_id: source.id, amount: carry.to_s("F"), currency: source.currency })
        target
      end
    end

    def self.checked(attributes)
      attributes = attributes.symbolize_keys
      raise ArgumentError, "Unknown budget field" unless (attributes.keys - FIELDS).empty?
      attributes
    end

    def execution_for!(user, committed_amount: nil, reserved_for_same_obligation: nil)
      raise ActiveRecord::RecordNotFound unless self.class.for_user(user).where(id: id).exists?
      actual, incomplete, issues = actual_amount(user)
      committed, fee_issues = committed_amount.nil? ? pending_fees_amount(user) : [ Decimal.money!(committed_amount, nonnegative: true), [] ]
      issues.concat(fee_issues)
      incomplete ||= fee_issues.any?
      effective = limit_amount + rollover_amount
      remaining = actual.nil? ? nil : effective - actual
      warnings = []
      warnings << "overspent" if remaining && remaining.negative?
      warnings << "warning_threshold_reached" if actual && effective.positive? && actual >= effective * warning_threshold
      children_total = BigDecimal("0")
      children.each do |child|
        quote = RateSnapshot.quote(from: child.currency, to: currency, date: child.start_on)
        if quote.missing?
          children_total = nil
          warnings << "child_limits_missing_rate"
          break
        end
        children_total += quote.convert(child.limit_amount + child.rollover_amount)
      end
      warnings << "child_limits_exceed_parent" if children_total && children_total > effective
      {
        budget_id: id, currency: currency, limit: limit_amount, rollover: rollover_amount,
        limit_effective: effective, actual: actual, committed: committed,
        reserved_for_same_obligation: reserved_for_same_obligation.nil? ? nil : Decimal.money!(reserved_for_same_obligation, nonnegative: true),
        remaining: remaining, uncommitted_remaining: remaining && committed && remaining - committed,
        child_limits_total: children_total, warnings: warnings,
        incomplete: incomplete, issues: issues
      }
    end

    def version_for!(user, kind:, before:, key: nil)
      versions.create!(family: user.family, actor: user, kind: kind, operation_key: key,
        from_data: before, to_data: version_data)
    end

    def version_data
      { "name" => name, "limit_amount" => limit_amount.to_s("F"), "currency" => currency,
        "rollover_amount" => rollover_amount.to_s("F"), "start_on" => start_on.iso8601,
        "end_on" => end_on.iso8601, "status" => status, "parent_id" => parent_id,
        "category_id" => category_id, "period_id" => period_id }
    end

    def payload
      attributes.slice("id", "project_id", "name", "start_on", "end_on", "currency", "limit_amount",
        "rollover_amount", "rollover_enabled", "parent_id", "period_id", "category_id", "sure_budget_id",
        "warning_threshold", "status", "lock_version").merge(
          "limit_amount" => limit_amount.to_s("F"), "rollover_amount" => rollover_amount.to_s("F"),
          "warning_threshold" => warning_threshold.to_s("F"))
    end

    private
      def valid_monetary_fields
        Decimal.money!(limit_amount, nonnegative: true) if limit_amount
        Decimal.money!(rollover_amount, nonnegative: true) if rollover_amount
        if warning_threshold && (!warning_threshold.between?(0, 1))
          errors.add(:warning_threshold, :invalid)
        end
      rescue ArgumentError
        errors.add(:base, "Invalid budget amount")
      end

      def valid_hierarchy
        unless project && family_id == project.family_id && start_on && end_on
          errors.add(:base, :invalid)
          return
        end
        if end_on < start_on || start_on < project.start_on || (project.end_on && end_on > project.end_on)
          errors.add(:base, "Budget dates outside project")
        end
        errors.add(:category, :invalid) if category && category.family_id != family_id
        errors.add(:sure_budget, :invalid) if sure_budget && sure_budget.family_id != family_id
        if period && (period.project_id != project_id || start_on < period.start_on || end_on > period.end_on)
          errors.add(:period, :invalid)
        end
        if parent_id
          ancestor = self.class.where(project_id: project_id).find_by(id: parent_id)
          if !ancestor || ancestor.start_on > start_on || ancestor.end_on < end_on ||
              (ancestor.category_id && ancestor.category_id != category_id)
            errors.add(:parent, :invalid)
          end
          seen = Set[id]
          while ancestor
            if seen.include?(ancestor.id)
              errors.add(:parent, "Hierarchy cycle")
              break
            end
            seen.add(ancestor.id)
            ancestor = ancestor.parent
          end
        end
        if persisted? && children.where("start_on < ? OR end_on > ?", start_on, end_on).exists?
          errors.add(:base, "Budget excludes child dates")
        end
        peers = self.class.where(project_id: project_id, parent_id: parent_id, category_id: category_id, currency: currency)
          .where("start_on <= ? AND end_on >= ?", end_on, start_on)
        peers = peers.where.not(id: id) if persisted?
        errors.add(:base, "Overlapping budget scope") if peers.exists?
      end

      def actual_amount(user)
        rows = project.allocations.visible_to(user).where(entry_date: start_on..end_on).order(:id).limit(10_001).to_a
        raise ArgumentError, "Budget calculation row limit exceeded" if rows.size > 10_000
        total = BigDecimal("0")
        issues = []
        deposits = refundable_deposit_amounts(rows.map(&:id))
        rows.each do |allocation|
          next unless category_id.nil? || allocation.category_id == category_id ||
            (allocation.category_id.nil? && allocation.entry&.transaction&.category_id == category_id)
          unless allocation.consistent?
            issues << { allocation_id: allocation.id, reason: "ledger_changed" }
            next
          end
          next unless allocation.direction == "expense"
          quote = RateSnapshot.quote(from: allocation.currency, to: currency, date: allocation.entry_date)
          if quote.missing?
            issues << { allocation_id: allocation.id, reason: "missing_rate" }
          else
            chargeable = allocation.amount - deposits.fetch(allocation.id, BigDecimal("0"))
            total += quote.convert(chargeable)
          end
        end
        # P1 refund links are authoritative; do not treat unrelated incoming
        # transactions as refunds or count a linked refund both ways.
        original_rows = project.allocations.visible_to(user).where(direction: "expense")
          .includes(:entry).limit(10_001).to_a
        raise ArgumentError, "Budget refund row limit exceeded" if original_rows.size > 10_000
        originals = original_rows.group_by(&:entry_id)
        original_deposits = refundable_deposit_amounts(original_rows.map(&:id))
        if originals.any?
          RefundLink.active.where(family_id: family_id, original_entry_id: originals.keys, refund_date: start_on..end_on)
            .includes(:original_entry).limit(10_001).each do |link|
            originals[link.original_entry_id].each do |allocation|
              next unless category_id.nil? || allocation.category_id == category_id ||
                (allocation.category_id.nil? && allocation.entry&.transaction&.category_id == category_id)
              unless link.consistent? && allocation.consistent?
                issues << { allocation_id: allocation.id, reason: "refund_changed" }
                next
              end
              chargeable = allocation.amount - original_deposits.fetch(allocation.id, BigDecimal("0"))
              share = chargeable / allocation.entry.amount.abs
              credited = link.applied_amount * share
              quote = RateSnapshot.quote(from: link.currency, to: currency, date: link.refund_date)
              if quote.missing?
                issues << { allocation_id: allocation.id, reason: "missing_refund_rate" }
              else
                total -= quote.convert(credited)
              end
            end
          end
        end
        [ issues.any? ? nil : total, issues.any?, issues ]
      end

      def refundable_deposit_amounts(allocation_ids)
        return {} if allocation_ids.empty? || !defined?(Abroa::FeeSettlement)
        FeeSettlement.where(kind: "payment", allocation_id: allocation_ids)
          .joins(fee_installment: :fee_plan).where(abroa_fee_plans: { kind: "deposit" })
          .group(:allocation_id).sum(:amount)
      end

      def pending_fees_amount(user)
        return [ BigDecimal("0"), [] ] unless defined?(Abroa::FeeInstallment)
        scope = FeeInstallment.joins(:fee_plan).where(due_on: start_on..end_on, state: "confirmed",
          abroa_fee_plans: { project_id: project_id, status: "active" })
        scope = scope.where(abroa_fee_plans: { category_id: category_id }) if category_id
        rows = scope.limit(10_001).to_a
        raise ArgumentError, "Budget fee row limit exceeded" if rows.size > 10_000
        total = BigDecimal("0")
        issues = []
        rows.each do |installment|
          next if installment.fee_plan.refundable_deposit?
          unless installment.readable_for?(user)
            issues << { fee_installment_id: installment.id, reason: "fee_source_not_visible" }
            next
          end
          if installment.settlements.any? { |payment| !payment.consistent? }
            issues << { fee_installment_id: installment.id, reason: "fee_ledger_changed" }
            next
          end
          quote = RateSnapshot.quote(from: installment.fee_plan.currency, to: currency,
            date: [ installment.due_on, Date.current ].min)
          if quote.missing?
            issues << { fee_installment_id: installment.id, reason: "missing_fee_rate" }
            next
          end
          total += quote.convert(installment.outstanding_amount)
        end
        [ issues.any? ? nil : total, issues ]
      end
  end
end
