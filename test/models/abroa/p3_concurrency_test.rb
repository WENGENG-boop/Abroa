require "test_helper"
require "concurrent"
require "timeout"

class Abroa::P3ConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "P3 concurrency", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "p3-concurrency-project")
    @budget = Abroa::BudgetNode.create_for!(@student, @project.id, attributes: {
      name: "Monthly budget", currency: "GBP", limit_amount: "1000",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "p3-concurrent-budget")
    @account = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "P3 concurrent bank", currency: "GBP", balance: 1000)
  end

  teardown do
    ids = Abroa::FundingPlan.where(project_id: @project.id).select(:id)
    receipt_ids = Abroa::FundingReceipt.where(funding_plan_id: ids).select(:id)
    Abroa::FundingReversal.where(funding_receipt_id: receipt_ids).delete_all
    Abroa::FundingReceipt.where(funding_plan_id: ids).delete_all
    Abroa::FundingNotice.where(funding_plan_id: ids).delete_all
    Abroa::FundingPlan.where(project_id: @project.id).delete_all
    Abroa::Proposal.where(project_id: @project.id).delete_all
    Abroa::Grant.where(project_id: @project.id).delete_all
    Abroa::RelationshipInvite.where(inviter_id: [ @student.id, @parent.id ]).delete_all
    Abroa::Relationship.where(student_user_id: @student.id, parent_user_id: @parent.id).delete_all
    Abroa::BudgetVersion.where(budget_node_id: @budget.id).delete_all
    Abroa::BudgetNode.where(id: @budget.id).delete_all
    Abroa::StudyProject.where(id: @project.id).delete_all
    @account.destroy!
    Abroa::Profile.where(user_id: [ @student.id, @parent.id ]).delete_all
  end

  test "two PostgreSQL sessions accept the same invitation only once" do
    invite, token = Abroa::RelationshipInvite.issue_for!(@student,
      recipient_email: @parent.email, recipient_role: "parent", key: "same-invite")
    values = race([ 1, 2 ]) do |i|
      Abroa::RelationshipInvite.accept_for!(User.find(@parent.id), token: token)
      :accepted
    end
    assert_equal [ :accepted, :rejected ], values.map(&:first).sort
    assert_equal 2, values.map(&:last).uniq.size
    assert_equal 1, Abroa::Relationship.where(student_user_id: @student.id, parent_user_id: @parent.id,
      status: "active").count
    assert_equal "accepted", invite.reload.status
  end

  test "student grant revoke and parent direct edit serialize safely" do
    link!
    grant = Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "budget_manage", resource_kind: "budget_node",
      resource_id: @budget.id, key: "specific-node")
    changes = race([ :edit, :revoke ]) do |op|
      if op == :edit
        Abroa::BudgetNode.parent_change_for!(User.find(@parent.id), @budget.id,
          version: 0, attributes: { limit_amount: "1100" })
        :edited
      else
        Abroa::Grant.revoke_for!(User.find(@student.id), @relation.id, grant.id,
          version: grant.lock_version)
        :revoked
      end
    end
    assert_includes changes.map(&:first), :revoked
    assert_equal "revoked", grant.reload.status
    assert_not Abroa::Grant.allowed?(@parent, @project, "budget_manage",
      resource_kind: "budget_node", resource_id: @budget.id)
    assert_includes [ BigDecimal("1000"), BigDecimal("1100") ], @budget.reload.limit_amount
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::BudgetNode.parent_change_for!(@parent, @budget.id,
        version: @budget.lock_version, attributes: { limit_amount: "1200" })
    end
  end

  test "concurrent budget approval and rejection cannot both resolve proposal" do
    link!
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "propose", key: "concurrent-propose")
    proposal = Abroa::Proposal.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, operation: "budget_update", target_id: @budget.id,
      expected_version: @budget.lock_version, payload: { limit_amount: "1600" },
      key: "concurrent-budget")
    proposal = Abroa::Proposal.submit_for!(@parent, proposal.id, version: proposal.lock_version)
    version = proposal.lock_version
    results = race([ :approve, :reject ]) do |op|
      if op == :approve
        Abroa::Proposal.accept_for!(User.find(@student.id), proposal.id, version: version)
      else
        Abroa::Proposal.reject_for!(User.find(@student.id), proposal.id, version: version)
      end
      :resolved
    end
    assert_equal [ :rejected, :resolved ], results.map(&:first).sort
    assert_includes %w[accepted rejected], proposal.reload.status
    assert_includes [ BigDecimal("1000"), BigDecimal("1600") ], @budget.reload.limit_amount
    assert_operator @budget.versions.where(kind: "parent_proposal").count, :<=, 1
  end

  test "two funding plans cannot match the same ledger entry simultaneously" do
    link!
    first, second = [ "first", "second" ].map do |key|
      plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
        project_id: @project.id, attributes: {
          name: key, amount: "500", currency: "GBP",
          frequency: "once", scheduled_on: "2025-02-10"
        }, key: "fund-#{key}")
      Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
        destination_account_id: @account.id)
    end
    entry = @account.entries.create!(entryable: Transaction.new, name: "Real transfer",
      amount: -400, currency: "GBP", date: Date.new(2025, 2, 10))
    balance = @account.reload.balance
    values = race([ first, second ]) do |plan|
      Abroa::FundingReceipt.match_for!(User.find(@student.id), plan.id,
        entry_id: entry.id, key: "match-#{plan.id}")
      :matched
    end
    assert_equal [ :matched, :rejected ], values.map(&:first).sort
    assert_equal 1, Abroa::FundingReceipt.where(entry_id: entry.id).count
    assert_equal BigDecimal("400"), first.reload.received_total + second.reload.received_total
    assert_equal balance, @account.reload.balance
  end

  test "two refund matches cannot reuse one actual bank outflow" do
    link!
    plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, attributes: {
        name: "Allowance", amount: "500", currency: "GBP",
        frequency: "once", scheduled_on: "2025-02-10"
      }, key: "refund-concurrency")
    plan = Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
      destination_account_id: @account.id)
    incoming = @account.entries.create!(entryable: Transaction.new, name: "Funding",
      amount: -500, currency: "GBP", date: Date.new(2025, 2, 10))
    receipt = Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: incoming.id, key: "receipt")
    outgoing = @account.entries.create!(entryable: Transaction.new, name: "Refund transfer",
      amount: 250, currency: "GBP", date: Date.new(2025, 2, 11))
    results = race([ 1, 2 ]) do |i|
      Abroa::FundingReversal.reverse_for!(User.find(@student.id), receipt.id,
        entry_id: outgoing.id, key: "refund-#{i}")
      :reversed
    end
    assert_equal [ :rejected, :reversed ], results.map(&:first).sort
    assert_equal 1, Abroa::FundingReversal.where(entry_id: outgoing.id).count
    assert_equal BigDecimal("250"), plan.reload.received_total
    assert_equal BigDecimal("250"), receipt.reload.reversals.sum(:native_amount)
  end

  private
    def link!
      _invite, token = Abroa::RelationshipInvite.issue_for!(@student,
        recipient_email: @parent.email, recipient_role: "parent", key: "concurrent-link")
      @relation = Abroa::RelationshipInvite.accept_for!(@parent, token: token)
    end

    def race(items)
      gate = Concurrent::CountDownLatch.new(items.size)
      threads = items.map do |item|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            backend_pid = ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
            gate.count_down
            raise "P3 concurrency barrier timed out" unless gate.wait(15)
            [ yield(item), backend_pid ]
          rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique,
            Abroa::RelationshipInvite::Conflict, Abroa::Relationship::Conflict,
            Abroa::Grant::Conflict, Abroa::BudgetNode::Conflict, Abroa::Proposal::Conflict,
            Abroa::FundingReceipt::Conflict, Abroa::FundingReversal::Conflict
            [ :rejected, backend_pid ]
          end
        end
      end
      Timeout.timeout(45) { threads.map(&:value) }
    ensure
      threads&.each { |thread| thread.kill if thread.alive?; thread.join }
    end
end
