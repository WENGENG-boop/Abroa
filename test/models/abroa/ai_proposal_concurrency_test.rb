require "test_helper"
require "concurrent"
require "timeout"

class Abroa::AiProposalConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@user,
      attributes: { name: "A14 concurrency checks", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "a14-concurrency-project")
    @budget = Abroa::BudgetNode.create_for!(@user, @project.id,
      attributes: { name: "AI concurrency budget", currency: "GBP", limit_amount: "1000",
        start_on: "2025-01-01", end_on: "2028-12-31" }, key: "a14-concurrency-budget")
  end

  teardown do
    if @project
      ids = Abroa::AiOperationProposal.where(project_id: @project.id).pluck(:id)
      Abroa::PlanningAuditEvent.where(resource_id: ids).delete_all
      Abroa::AiOperationProposal.where(id: ids).delete_all
      if @budget
        Abroa::PlanningAuditEvent.where(resource_id: @budget.id).delete_all
        Abroa::BudgetVersion.where(budget_node_id: @budget.id).delete_all
        Abroa::BudgetNode.where(id: @budget.id).delete_all
      end
      Abroa::PlanningAuditEvent.where(resource_id: @project.id).delete_all
      Abroa::StudyProject.where(id: @project.id).delete_all
    end
  end

  test "two real PG sessions cannot confirm different versions or double-execute an AI operation" do
    proposal, token = Abroa::AiOperationProposal.propose_for!(@user,
      operation: "budget_update", resource_id: @budget.id,
      parameters: { limit_amount: "1200" }, key: "a14-concurrent")
    results = race do
      Abroa::AiOperationProposal.confirm_for!(User.find(@user.id), proposal.id,
        token: token, version: proposal.lock_version)
      :confirmed
    rescue Abroa::AiOperationProposal::Conflict
      :conflict
    end
    assert_equal [ :confirmed, :conflict ], results.map(&:first).sort
    assert_equal 2, results.map(&:last).uniq.size
    assert_equal "confirmed", proposal.reload.status
    executions = race do
      Abroa::AiOperationProposal.execute_for!(User.find(@user.id), proposal.id).status
    end
    assert_equal %w[executed executed], executions.map(&:first).sort
    assert_equal 2, executions.map(&:last).uniq.size
    assert_equal BigDecimal("1200"), @budget.reload.limit_amount
    assert_equal 1, Abroa::PlanningAuditEvent.where(event_type: "ai_proposal.executed",
      resource_id: proposal.id).count
  end

  private
    def race
      ready = Concurrent::CountDownLatch.new(2)
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            pid = ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
            ready.count_down
            raise "Barrier timed out" unless ready.wait(15)
            [ yield, pid ]
          end
        end
      end
      Timeout.timeout(45) { threads.map(&:value) }
    ensure
      threads&.each { |thread| thread.kill if thread.alive?; thread.join }
    end
end
