require "test_helper"

class Abroa::ProfileTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
  end

  test "reading a default profile does not create a record" do
    assert_no_difference "Abroa::Profile.count" do
      profile = Abroa::Profile.for_user(@user)
      assert_equal "simple", profile.mode
      assert_equal "role", profile.onboarding_step
      assert_not profile.student_enabled?
      assert_not profile.parent_enabled?
    end
  end

  test "student and parent modes do not change the original user role or family" do
    role, family_id = @user.role, @user.family_id
    profile = Abroa::Profile.change_for!(@user, version: 0, attributes: {
      student_enabled: true, parent_enabled: true, mode: "professional"
    })
    assert profile.student_enabled?
    assert profile.parent_enabled?
    assert_equal role, @user.reload.role
    assert_equal family_id, @user.family_id
    assert_equal 1, profile.lock_version
    assert_equal 1, Abroa::Profile.where(user: @user).count
  end

  test "invalid country currency timezone and mode are rejected" do
    profile = Abroa::Profile.new(user: @user, origin_country: "ZZZ",
      display_currency: "INVALID", timezone: "Not/A/Zone", mode: "other")
    assert_not profile.valid?
    %i[origin_country display_currency timezone mode].each do |field|
      assert profile.errors[field].present?, field.to_s
    end
  end

  test "stale updates do not overwrite newer preferences" do
    Abroa::Profile.change_for!(@user, version: 0, attributes: { mode: "custom" })
    assert_raises(Abroa::Profile::Conflict) do
      Abroa::Profile.change_for!(@user, version: 0, attributes: { mode: "simple" })
    end
    assert_equal "custom", Abroa::Profile.for_user(@user).mode
  end

  test "onboarding allows optional steps to be skipped without a project" do
    profile = Abroa::Profile.change_for!(@user, version: 0, attributes: { student_enabled: true })
    profile = Abroa::Profile.advance_for!(@user, version: profile.lock_version, step: "review")
    completed = Abroa::Profile.complete_for!(@user, version: profile.lock_version, key: "complete-1")
    assert_equal "complete", completed.onboarding_step
    assert completed.completed_at.present?
    replay = Abroa::Profile.complete_for!(@user, version: profile.lock_version, key: "complete-1")
    assert_equal completed.completed_at, replay.completed_at
    assert_equal completed.lock_version, replay.lock_version
  end

  test "completion requires a chosen role and rejects a different request with the same key" do
    assert_raises(ActiveRecord::RecordInvalid) do
      Abroa::Profile.complete_for!(@user, version: 0, key: "complete-1")
    end
    profile = Abroa::Profile.change_for!(@user, version: 0, attributes: { parent_enabled: true })
    Abroa::Profile.complete_for!(@user, version: profile.lock_version, key: "complete-1")
    assert_raises(Abroa::Profile::Conflict) do
      Abroa::Profile.complete_for!(@user, version: profile.lock_version + 1, key: "complete-1")
    end
  end
end
