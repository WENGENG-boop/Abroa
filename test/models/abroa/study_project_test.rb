require "test_helper"

class Abroa::StudyProjectTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    @attributes = { name: "UK study", country: "GB", origin_country: "CN",
      city: "London", school: "University", start_on: "2025-01-01", end_on: "2025-12-31",
      currency: "GBP", timezone: "Europe/London" }
  end

  test "project belongs to a single user and accepts global regional preferences" do
    project = Abroa::StudyProject.create_for!(@user, attributes: @attributes, key: "project-one")
    assert_equal @user.id, project.owner_id
    assert_equal "GBP", project.currency
    assert_equal "planning", project.status
    assert_equal project.id, Abroa::StudyProject.create_for!(@user, attributes: @attributes, key: "project-one").id
    assert_raises(Abroa::StudyProject::Conflict) do
      Abroa::StudyProject.create_for!(@user, attributes: @attributes.merge(name: "Different"), key: "project-one")
    end
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::StudyProject.find_for!(@other, project.id) }
  end

  test "archive and restore preserve the prior lifecycle state and use optimistic versions" do
    project = Abroa::StudyProject.create_for!(@user, attributes: @attributes, key: "project-one")
    project = Abroa::StudyProject.change_for!(@user, project.id, version: project.lock_version,
      attributes: { status: "active" })
    archived = Abroa::StudyProject.archive_for!(@user, project.id, version: project.lock_version)
    assert_equal "archived", archived.status
    assert_raises(Abroa::StudyProject::Conflict) do
      Abroa::StudyProject.change_for!(@user, project.id, version: archived.lock_version, attributes: { name: "Changed" })
    end
    restored = Abroa::StudyProject.restore_for!(@user, project.id, version: archived.lock_version)
    assert_equal "active", restored.status
    assert_nil restored.archived_at
    assert_raises(Abroa::StudyProject::Conflict) do
      Abroa::StudyProject.change_for!(@user, project.id, version: 0, attributes: { name: "Stale" })
    end
  end

  test "invalid country currency and dates are rejected" do
    [ { country: "ZZZ" }, { currency: "UNKNOWN" }, { end_on: "2024-01-01" } ].each_with_index do |fields, i|
      assert_no_difference "Abroa::StudyProject.count" do
        assert_raises(ArgumentError, ActiveRecord::RecordInvalid) do
          Abroa::StudyProject.create_for!(@user, attributes: @attributes.merge(fields), key: "bad-#{i}")
        end
      end
    end
  end

  test "nested periods must remain in their parent and project and cannot cycle" do
    project = Abroa::StudyProject.create_for!(@user, attributes: @attributes, key: "project-one")
    year = Abroa::StudyPeriod.create_for!(@user, project.id, attributes: {
      kind: "year", name: "Year 1", start_on: "2025-01-01", end_on: "2025-12-31" })
    term = Abroa::StudyPeriod.create_for!(@user, project.id, attributes: {
      kind: "term", name: "Term 1", start_on: "2025-01-01", end_on: "2025-06-30", parent_id: year.id })
    assert_raises(ActiveRecord::RecordInvalid) do
      Abroa::StudyPeriod.change_for!(@user, project.id, year.id, version: year.lock_version,
        attributes: { parent_id: term.id })
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      Abroa::StudyPeriod.change_for!(@user, project.id, year.id, version: year.lock_version,
        attributes: { start_on: "2025-02-01" })
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      Abroa::StudyProject.change_for!(@user, project.id, version: project.lock_version,
        attributes: { end_on: "2025-05-01" })
    end
  end
end
