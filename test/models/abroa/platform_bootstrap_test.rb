require "test_helper"

class Abroa::PlatformBootstrapTest < ActiveSupport::TestCase
  setup do
    @legacy = users(:sure_support_staff)
    @ordinary = users(:family_member)
  end

  test "Sure super admin has no implicit P5 role and console bootstrap requires explicit approval" do
    assert_not Abroa::PlatformRoleAssignment.permitted?(@legacy, "roles.manage")
    assert_raises(Abroa::PlatformBootstrap::InvalidApproval) do
      Abroa::PlatformBootstrap.grant_initial_system_admin!(
        user_id: @legacy.id, approval: "yes"
      )
    end
    assert_equal 0, Abroa::PlatformRoleAssignment.where(user: @legacy).count
    assert_equal 0, Abroa::PlatformAuditEvent.where(action: "role_grant").count
  end

  test "ordinary users cannot be bootstrapped even with phrase" do
    assert_raises(Abroa::PlatformBootstrap::InvalidApproval) do
      Abroa::PlatformBootstrap.grant_initial_system_admin!(
        user_id: @ordinary.id, approval: Abroa::PlatformBootstrap::APPROVAL_PHRASE
      )
    end
    assert_not Abroa::PlatformRoleAssignment.exists?(user: @ordinary)
  end

  test "only first administrator is authorized, append-only audited, no tenancy grants" do
    role = Abroa::PlatformBootstrap.grant_initial_system_admin!(
      user_id: @legacy.id, approval: Abroa::PlatformBootstrap::APPROVAL_PHRASE
    )
    assert_equal "system_admin", role.role
    assert Abroa::PlatformRoleAssignment.permitted?(@legacy, "roles.manage")
    assert_raises(Abroa::PlatformBootstrap::AlreadyInitialized) do
      Abroa::PlatformBootstrap.grant_initial_system_admin!(
        user_id: @legacy.id, approval: Abroa::PlatformBootstrap::APPROVAL_PHRASE
      )
    end
    assert_equal 1, Abroa::PlatformRoleAssignment.count
    audit = Abroa::PlatformAuditEvent.last
    assert_equal "granted", audit.outcome
    assert_equal @legacy.id, audit.actor_user_id
    assert_equal "one_time_local_bootstrap", audit.safe_changes["method"]
    assert_not_equal @ordinary.family_id, @legacy.family_id
  end
end
