require "test_helper"

class Abroa::RelationshipTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @same_family = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "London", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "parent-test-project")
  end

  test "relationship requires a recipient-bound single use invitation" do
    invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "hello")
    assert_equal invite.id, Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "hello").first.id
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::RelationshipInvite.accept_for!(@same_family, token: token) }
    assert_raises(Abroa::RelationshipInvite::Conflict) do
      Abroa::RelationshipInvite.issue_for!(@parent, recipient_email: "different@example.com",
        recipient_role: "student", key: "hello")
    end
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    assert_equal "active", relation.status
    assert_equal @student.id, relation.student_user_id
    assert_equal @parent.id, relation.parent_user_id
    assert_not_equal relation.student_family_id, relation.parent_family_id
    assert_raises(Abroa::RelationshipInvite::Conflict) { Abroa::RelationshipInvite.accept_for!(@student, token: token) }
  end

  test "relationship alone grants nothing and project access is explicit" do
    _invite, token = Abroa::RelationshipInvite.issue_for!(@student,
      recipient_email: @parent.email, recipient_role: "parent", key: "student-invites")
    relation = Abroa::RelationshipInvite.accept_for!(@parent, token: token)
    assert_not Abroa::Grant.allowed?(@parent, @project, "summary")
    assert_empty Abroa::Grant.projects_for_parent(@parent, capability: "summary")
    grant = Abroa::Grant.create_for!(@student, relation.id, project_id: @project.id,
      capability: "summary", key: "approve-1")
    assert Abroa::Grant.allowed?(@parent, @project, "summary")
    assert_not Abroa::Grant.allowed?(@parent, @project, "budget_manage")
    assert_equal [ @project.id ], Abroa::Grant.projects_for_parent(@parent, capability: "summary").pluck(:id)
    Abroa::Grant.revoke_for!(@student, relation.id, grant.id, version: grant.lock_version)
    assert_not Abroa::Grant.allowed?(@parent, @project, "summary")
  end

  test "expired invitation, same family and outsider roles are rejected" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::RelationshipInvite.issue_for!(@student, recipient_email: @same_family.email,
        recipient_role: "parent", key: "same-family")
    end
    invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "expires")
    invite.update!(expires_at: 1.minute.ago)
    assert_raises(Abroa::RelationshipInvite::Conflict) { Abroa::RelationshipInvite.accept_for!(@student, token: token) }
    assert_equal 0, Abroa::Relationship.count
  end

  test "revoke relation immediately denies all grants without touching student ledger" do
    _invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "revoke")
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    grant = Abroa::Grant.create_for!(@student, relation.id, project_id: @project.id,
      capability: "summary", key: "grant")
    assert Abroa::Grant.allowed?(@parent, @project, "summary")
    Abroa::Relationship.revoke_for!(@student, relation.id, version: relation.lock_version)
    assert_not Abroa::Grant.allowed?(@parent, @project, "summary")
    assert_equal "revoked", grant.reload.status
    assert_equal @student.family_id, @project.reload.family_id
    assert_equal 0, Entry.where(account_id: Account.where(family_id: @parent.family_id).select(:id),
      name: "Abroa virtual funding").count
  end
end
