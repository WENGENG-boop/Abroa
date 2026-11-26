require "test_helper"

class Abroa::ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @attributes = { name: "Private study project", country: "GB", currency: "GBP", timezone: "London", start_on: "2027-01-15" }
  end

  test "project creation uses server authorization and idempotency" do
    sign_in @user
    key = SecureRandom.uuid

    assert_difference -> { Abroa::StudyProject.count }, 1 do
      post abroa_projects_url, params: { project: @attributes, idempotency_key: key }
      assert_response :see_other
    end

    project = Abroa::StudyProject.for_user(@user).find_by!(name: @attributes[:name])
    assert_redirected_to abroa_project_path(project)
    assert_no_difference -> { Abroa::StudyProject.count } do
      post abroa_projects_url, params: { project: @attributes, idempotency_key: key }
      assert_redirected_to abroa_project_path(project)
    end
    get abroa_project_url(project)
    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "other family cannot view or list a student's project" do
    project = Abroa::StudyProject.create_for!(@user, attributes: @attributes, key: SecureRandom.uuid)
    sign_in users(:empty)
    get abroa_projects_url
    assert_response :success
    assert_no_match /Private study project/, response.body

    get abroa_project_url(project)
    assert_response :not_found
  end

  test "invalid project is not persisted" do
    sign_in @user
    assert_no_difference -> { Abroa::StudyProject.count } do
      post abroa_projects_url, params: { project: @attributes.merge(country: "XX"), idempotency_key: SecureRandom.uuid }
    end
    assert_response :unprocessable_entity
  end
end
