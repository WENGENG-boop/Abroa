require "test_helper"

class Abroa::ParentPlanningTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @outsider = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    _invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "plan-invite")
    @relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "Study", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "parent-planning-test")
    @budget = Abroa::BudgetNode.create_for!(@student, @project.id, attributes: {
      name: "Rent", start_on: "2025-01-01", end_on: "2025-12-31",
      currency: "GBP", limit_amount: "1000"
    }, key: "rent-budget")
    @idea = { name: "Rent", limit_amount: "1200" }
  end

  test "independent parent draft never writes a student's budget or ledger" do
    draft = Abroa::PlanningDraft.create_for!(@parent, attributes: {
      title: "New budget", kind: "budget",
      payload: { name: "Rent", currency: "GBP", start_on: "2025-01-01",
        end_on: "2025-12-31", limit_amount: "1200" }
    }, key: "draft-1")
    assert_equal @parent.family_id, draft.family_id
    assert_equal @parent.id, draft.parent_user_id
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::PlanningDraft.find_for!(@student, draft.id) }
    assert_equal draft.id, Abroa::PlanningDraft.create_for!(@parent, attributes: {
      title: "New budget", kind: "budget",
      payload: { name: "Rent", currency: "GBP", start_on: "2025-01-01",
        end_on: "2025-12-31", limit_amount: "1200" }
    }, key: "draft-1").id
    draft = Abroa::PlanningDraft.change_for!(@parent, draft.id, version: draft.lock_version,
      attributes: { title: "Revised" })
    assert_equal "Revised", draft.title
  end

  test "parent draft converts to a proposal snapshot and follows student decision" do
    allow_propose
    payload = { name: "Draft Materials", limit_amount: "200", currency: "GBP",
      category_id: categories(:food_and_drink).id,
      start_on: "2025-01-01", end_on: "2025-12-31" }
    draft = Abroa::PlanningDraft.create_for!(@parent,
      attributes: { title: "Materials plan", kind: "budget", payload: payload }, key: "draft-to-proposal")
    initial_count = Abroa::BudgetNode.where(project_id: @project.id).count
    proposal = Abroa::Proposal.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, operation: "budget_create", target_id: @project.id,
      expected_version: @project.lock_version, payload: payload, planning_draft_id: draft.id,
      key: "link-draft-to-proposal")
    assert_equal draft.id, proposal.planning_draft_id
    assert_equal "submitted", draft.reload.status
    assert_raises(Abroa::PlanningDraft::Conflict) do
      Abroa::PlanningDraft.change_for!(@parent, draft.id, version: draft.lock_version,
        attributes: { title: "Unexpected edit" })
    end
    assert_equal initial_count, Abroa::BudgetNode.where(project_id: @project.id).count
    proposal = Abroa::Proposal.submit_for!(@parent, proposal.id, version: proposal.lock_version)
    accepted = Abroa::Proposal.accept_for!(@student, proposal.id, version: proposal.lock_version)
    assert_equal "accepted", accepted.status
    assert_equal "accepted", draft.reload.status
    assert_equal initial_count + 1, Abroa::BudgetNode.where(project_id: @project.id).count
    assert_equal "Draft Materials", Abroa::BudgetNode.find(accepted.applied_resource_id).name
  end

  test "parent proposal requires propose grant and student rejection does not write" do
    assert_raises(ActiveRecord::RecordNotFound) do
      propose_update(key: "not-allowed")
    end
    allow_propose
    proposed = propose_update(key: "allowed")
    assert_equal "draft", proposed.status
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
    proposed = Abroa::Proposal.submit_for!(@parent, proposed.id, version: proposed.lock_version)
    assert_equal "pending", proposed.status
    rejected = Abroa::Proposal.reject_for!(@student, proposed.id, version: proposed.lock_version)
    assert_equal "rejected", rejected.status
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
    assert_raises(Abroa::Proposal::Conflict) do
      Abroa::Proposal.accept_for!(@student, proposed.id, version: proposed.lock_version)
    end
  end

  test "accept applies one budget version, replays safely, and catches stale budget versions" do
    allow_propose
    proposal = propose_update(key: "confirm")
    proposal = Abroa::Proposal.submit_for!(@parent, proposal.id, version: proposal.lock_version)
    accepted = Abroa::Proposal.accept_for!(@student, proposal.id, version: proposal.lock_version)
    assert_equal "accepted", accepted.status
    assert_equal BigDecimal("1200"), @budget.reload.limit_amount
    versions = @budget.versions.count
    assert_equal accepted.id, Abroa::Proposal.accept_for!(@student, proposal.id,
      version: proposal.lock_version).id
    assert_equal versions, @budget.versions.count
    stale = propose_update(key: "stale", expected_version: @budget.lock_version)
    stale = Abroa::Proposal.submit_for!(@parent, stale.id, version: stale.lock_version)
    Abroa::BudgetNode.change_for!(@student, @budget.id, version: @budget.lock_version,
      attributes: { limit_amount: "1300" })
    assert_raises(Abroa::Proposal::Conflict) do
      Abroa::Proposal.accept_for!(@student, stale.id, version: stale.lock_version)
    end
    assert_equal BigDecimal("1300"), @budget.reload.limit_amount
  end

  test "proposal creates a budget only after student approves, preserving hierarchy" do
    allow_propose
    initial = Abroa::BudgetNode.where(project_id: @project.id).count
    proposal = Abroa::Proposal.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, operation: "budget_create", target_id: @project.id,
      expected_version: @project.lock_version, key: "create-budget-proposal",
      payload: { name: "Materials", currency: "GBP", limit_amount: "240",
        category_id: categories(:food_and_drink).id,
        start_on: "2025-01-01", end_on: "2025-12-31" })
    assert_equal initial, Abroa::BudgetNode.where(project_id: @project.id).count
    proposal = Abroa::Proposal.submit_for!(@parent, proposal.id, version: proposal.lock_version)
    proposal = Abroa::Proposal.accept_for!(@student, proposal.id, version: proposal.lock_version)
    assert_equal "accepted", proposal.status
    assert_equal initial + 1, Abroa::BudgetNode.where(project_id: @project.id).count
    created = Abroa::BudgetNode.find(proposal.applied_resource_id)
    assert_equal "Materials", created.name
    assert_equal @project.id, created.project_id
    assert_equal created.id, Abroa::Proposal.accept_for!(@student, proposal.id,
      version: proposal.lock_version).applied_resource_id
  end

  test "a parent proposes a school change but cannot directly modify the student's project" do
    allow_propose
    proposal = Abroa::Proposal.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, operation: "study_project_update", target_id: @project.id,
      expected_version: @project.lock_version, key: "school-change",
      payload: { school: "Example University", city: "London" })
    assert_nil @project.reload.school
    proposal = Abroa::Proposal.submit_for!(@parent, proposal.id, version: proposal.lock_version)
    proposal = Abroa::Proposal.accept_for!(@student, proposal.id, version: proposal.lock_version)
    assert_equal "Example University", @project.reload.school
    assert_equal @project.id, proposal.applied_resource_id
    assert_raises(Abroa::Proposal::Conflict) do
      Abroa::Proposal.create_for!(@parent, relationship_id: @relation.id,
        project_id: @project.id, operation: "study_project_update", target_id: @project.id,
        expected_version: 0, key: "stale-school", payload: { school: "Other University" })
    end
  end

  test "revoke propose permission before acceptance prevents execution" do
    grant = allow_propose
    proposal = propose_update(key: "revoke-before-accept")
    proposal = Abroa::Proposal.submit_for!(@parent, proposal.id, version: proposal.lock_version)
    Abroa::Grant.revoke_for!(@student, @relation.id, grant.id, version: grant.lock_version)
    assert_raises(Abroa::Proposal::Conflict) do
      Abroa::Proposal.accept_for!(@student, proposal.id, version: proposal.lock_version)
    end
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
  end

  test "direct edit is restricted to a specifically granted budget node" do
    other = Abroa::BudgetNode.create_for!(@student, @project.id, attributes: {
      name: "Food", start_on: "2025-01-01", end_on: "2025-12-31",
      currency: "GBP", limit_amount: "500", category_id: categories(:food_and_drink).id
    }, key: "other-budget")
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "budget_manage", resource_kind: "budget_node",
      resource_id: @budget.id, key: "rent-manage-only")
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::BudgetNode.parent_change_for!(@parent, other.id,
        version: other.lock_version, attributes: { limit_amount: "600" })
    end
    edited = Abroa::BudgetNode.parent_change_for!(@parent, @budget.id,
      version: @budget.lock_version, attributes: { limit_amount: "1500" })
    assert_equal BigDecimal("1500"), edited.limit_amount
    provenance = edited.versions.find_by!(kind: "parent_direct")
    assert_equal @parent.id, provenance.actor_id
    assert_equal @student.family_id, provenance.family_id
    assert_equal BigDecimal("500"), other.reload.limit_amount
  end

  private
    def allow_propose
      Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
        capability: "propose", key: "propose-grant")
    end

    def propose_update(key:, expected_version: @budget.lock_version)
      Abroa::Proposal.create_for!(@parent, relationship_id: @relation.id,
        project_id: @project.id, operation: "budget_update", target_id: @budget.id,
        payload: @idea, expected_version: expected_version, key: key)
    end
end
