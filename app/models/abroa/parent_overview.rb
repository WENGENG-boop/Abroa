module Abroa
  # Deliberately narrow, read-only projection. The caller must hold an active,
  # project-specific Grant. Never changes Current.family or serializes whole
  # Sure Account/Entry/Transaction rows into the parent response.
  class ParentOverview
    MAX_DETAIL_ROWS = 200

    def self.projects_scope(parent)
      Grant.projects_for_parent(parent, capability: "summary")
    end

    def self.projects_for(parent)
      projects_scope(parent).order(:id).limit(101).map { |project| project_data(project) }
    end

    def self.project_for!(parent, project_id)
      project = authorized_project!(parent, project_id, "summary")
      student = project.owner
      dates = project_dates(project)
      spending = ProjectSummary.for_user(student, project.id, start_on: dates.first.iso8601,
        end_on: dates.last.iso8601, currency: project.currency)
      result = {
        project: project_data(project),
        period: { start_on: dates.first.iso8601, end_on: dates.last.iso8601 },
        consumption: { currency: project.currency, net_amount: spending[:net_consumption],
          incomplete: spending[:incomplete] }
      }
      result[:budgets] = budget_aggregate(project, student) if Grant.allowed?(parent, project, "budget_read")
      result[:fees] = fee_aggregate(project, student) if Grant.allowed?(parent, project, "fees_read")
      pools = allowed_pool_scope(parent, project)
      result[:pools] = pool_aggregate(project, pools) if pools.exists?
      result[:cash] = cash_aggregate(project, student) if Grant.allowed?(parent, project, "account_balance")
      result[:funding] = funding_aggregate(parent, project)
      result
    end

    def self.budgets_scope!(parent, project_id)
      project = authorized_project!(parent, project_id, "budget_read")
      BudgetNode.for_user(project.owner).where(project_id: project.id)
    end

    def self.fees_scope!(parent, project_id)
      project = authorized_project!(parent, project_id, "fees_read")
      FeePlan.for_user(project.owner).where(project_id: project.id)
    end

    def self.pools_scope!(parent, project_id)
      project = authorized_project!(parent, project_id, "summary")
      pools = allowed_pool_scope(parent, project)
      raise ActiveRecord::RecordNotFound unless pools.exists?
      pools
    end

    def self.expenses_scope!(parent, project_id)
      project = authorized_project!(parent, project_id, "transaction_details")
      EntryAllocation.where(project_id: project.id, family_id: project.family_id).visible_to(project.owner)
    end

    def self.funding_scope!(parent, project_id)
      project = authorized_project!(parent, project_id, "summary")
      FundingPlan.where(project_id: project.id, parent_user_id: parent.id,
        relationship_id: Relationship.where(parent_user_id: parent.id, status: "active").select(:id))
    end

    def self.budget_data(node)
      { id: node.id, name: node.name, currency: node.currency, status: node.status,
        period_start_on: node.start_on.iso8601, period_end_on: node.end_on.iso8601,
        limit_amount: node.limit_amount.to_s("F"), rollover_amount: node.rollover_amount.to_s("F") }
    end

    def self.fee_data(fee, student)
      result = fee.payload_for(student)
      { id: fee.id, name: fee.name, kind: fee.kind, currency: fee.currency,
        status: fee.status, amount_due: result[:amount_due],
        paid_amount: result[:paid_amount], outstanding_amount: result[:outstanding_amount],
        incomplete: result[:incomplete] }
    end

    def self.pool_data(pool)
      { id: pool.id, name: pool.name, kind: pool.kind, currency: pool.currency,
        target_amount: pool.target_amount&.to_s("F"), status: pool.status }
    end

    def self.expense_data(allocation)
      return { id: allocation.id, incomplete: true } unless allocation.consistent?
      { id: allocation.id, entry_id: allocation.entry_id, date: allocation.entry_date.iso8601,
        amount: allocation.amount.to_s("F"), currency: allocation.currency, direction: allocation.direction }
    end

    def self.budgets_for!(parent, project_id)
      project = authorized_project!(parent, project_id, "budget_read")
      BudgetNode.for_user(project.owner).where(project_id: project.id)
        .order(:id).limit(MAX_DETAIL_ROWS).map do |node|
        { id: node.id, name: node.name, currency: node.currency, status: node.status,
          period_start_on: node.start_on.iso8601, period_end_on: node.end_on.iso8601,
          limit_amount: node.limit_amount.to_s("F"), rollover_amount: node.rollover_amount.to_s("F") }
      end
    end

    def self.fees_for!(parent, project_id)
      project = authorized_project!(parent, project_id, "fees_read")
      FeePlan.for_user(project.owner).where(project_id: project.id)
        .order(:id).limit(MAX_DETAIL_ROWS).map do |fee|
        result = fee.payload_for(project.owner)
        { id: fee.id, name: fee.name, kind: fee.kind, currency: fee.currency,
          status: fee.status, amount_due: result[:amount_due],
          paid_amount: result[:paid_amount], outstanding_amount: result[:outstanding_amount],
          incomplete: result[:incomplete] }
      end
    end

    def self.pools_for!(parent, project_id)
      project = authorized_project!(parent, project_id, "summary")
      pools = allowed_pool_scope(parent, project)
      pools.order(:id).limit(MAX_DETAIL_ROWS).map do |pool|
        { id: pool.id, name: pool.name, kind: pool.kind, currency: pool.currency,
          target_amount: pool.target_amount&.to_s("F"), status: pool.status }
      end
    end

    def self.expenses_for!(parent, project_id)
      project = authorized_project!(parent, project_id, "transaction_details")
      scoped = EntryAllocation.where(project_id: project.id, family_id: project.family_id)
        .visible_to(project.owner).order(:id).limit(MAX_DETAIL_ROWS)
      scoped.map do |allocation|
        if allocation.consistent?
          { id: allocation.id, entry_id: allocation.entry_id, date: allocation.entry_date.iso8601,
            amount: allocation.amount.to_s("F"), currency: allocation.currency, direction: allocation.direction }
        else
          { id: allocation.id, incomplete: true }
        end
      end
    end

    def self.funding_for!(parent, project_id)
      project = authorized_project!(parent, project_id, "summary")
      FundingPlan.where(project_id: project.id, parent_user_id: parent.id,
        relationship_id: Relationship.where(parent_user_id: parent.id, status: "active").select(:id))
        .order(:id).limit(MAX_DETAIL_ROWS).map { |plan| plan.payload_for(parent) }
    end

    def self.authorized_project!(parent, project_id, capability)
      raise ActiveRecord::RecordNotFound unless parent&.active? && !parent.guest? &&
        Profile.for_user(parent).parent_enabled?
      scope = Grant.projects_for_parent(parent, capability: "summary")
      project = scope.find(project_id)
      raise ActiveRecord::RecordNotFound unless Grant.allowed?(parent, project, capability)
      project
    end

    def self.project_data(project)
      { id: project.id, name: project.name, country: project.country,
        currency: project.currency, status: project.status }
    end

    def self.project_dates(project)
      first = project.start_on
      last = [ project.end_on || first + 3650, first + 3660 ].min
      [ first, last ]
    end

    def self.budget_aggregate(project, student)
      roots = BudgetNode.for_user(student).where(project_id: project.id,
        parent_id: nil, status: "active").order(:start_on, :end_on).limit(501).to_a
      return { currency: project.currency, planned_amount: nil, incomplete: true } if roots.size > 500
      if roots.any? { |node| node.currency != project.currency } ||
          roots.each_cons(2).any? { |a, b| a.end_on >= b.start_on }
        return { currency: project.currency, planned_amount: nil, incomplete: true }
      end
      planned = roots.sum(BigDecimal("0")) { |node| node.limit_amount + node.rollover_amount }
      { currency: project.currency, planned_amount: planned.to_s("F"), incomplete: false }
    end

    def self.fee_aggregate(project, student)
      rows = FeePlan.for_user(student).where(project_id: project.id, status: "active").limit(501).to_a
      return { currency: project.currency, outstanding_amount: nil, incomplete: true } if rows.size > 500 ||
        rows.any? { |fee| fee.currency != project.currency }
      incomplete = rows.any? { |fee| fee.payload_for(student)[:incomplete] }
      if incomplete
        return { currency: project.currency, outstanding_amount: nil, incomplete: true }
      end
      due = rows.sum(BigDecimal("0"), &:amount_due)
      paid = rows.sum(BigDecimal("0"), &:paid_amount)
      outstanding = rows.sum(BigDecimal("0"), &:outstanding_amount)
      { currency: project.currency, amount_due: due.to_s("F"),
        paid_amount: paid.to_s("F"), outstanding_amount: outstanding.to_s("F"),
        incomplete: false }
    end

    def self.allowed_pool_scope(parent, project)
      grants = Grant.scoped_to_parent(parent, capability: "pool_manage").where(project_id: project.id)
      general = grants.where(resource_kind: "project", resource_id: nil).exists?
      base = FundPool.where(family_id: project.family_id, project_id: project.id, status: "active")
      general ? base : base.where(id: grants.where(resource_kind: "fund_pool").select(:resource_id))
    end

    def self.pool_aggregate(project, pools)
      rows = pools.limit(501).to_a
      if rows.size > 500 || rows.any? { |pool| pool.currency != project.currency || pool.target_amount.nil? }
        return { currency: project.currency, target_amount: nil, incomplete: true }
      end
      target = rows.sum(BigDecimal("0"), &:target_amount)
      # Target != allocated cash, do not expose Goal allocation or Account IDs.
      { currency: project.currency, target_amount: target.to_s("F"), incomplete: false }
    end

    def self.cash_aggregate(project, student)
      permitted = student.family.accounts.accessible_by(student)
      ids = ProjectAccount.where(family_id: project.family_id, project_id: project.id).select(:account_id)
      rows = permitted.where(id: ids).order(:id).limit(501).to_a
      if rows.size > 500 || rows.any? { |account| account.currency != project.currency }
        return { currency: project.currency, balance: nil, incomplete: true }
      end
      { currency: project.currency, balance: rows.sum(BigDecimal("0"), &:balance).to_s("F"),
        incomplete: false }
    end

    def self.funding_aggregate(parent, project)
      rows = FundingPlan.where(project_id: project.id, parent_user_id: parent.id,
        relationship_id: Relationship.where(parent_user_id: parent.id, status: "active").select(:id))
        .limit(501).to_a
      if rows.size > 500 || rows.any? { |plan| plan.currency != project.currency || !plan.evidence_consistent? }
        return { currency: project.currency, received_amount: nil, incomplete: true }
      end
      planned = rows.reject { |plan| %w[cancelled rejected].include?(plan.status) }
        .sum(BigDecimal("0"), &:planned_total)
      received = rows.sum(BigDecimal("0"), &:received_total)
      pending = rows.sum(BigDecimal("0"), &:pending_match_total)
      { currency: project.currency, planned_amount: planned.to_s("F"),
        received_amount: received.to_s("F"), pending_matching_amount: pending.to_s("F"),
        incomplete: false }
    end
  end
end
