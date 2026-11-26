require "application_system_test_case"

class AbroaStudyProjectsSystemTest < ApplicationSystemTestCase
  test "student creates a project through the dashboard and sees persisted details" do
    user = users(:family_admin)
    sign_in user
    click_link "Study projects"
    click_link "New study project", match: :first
    fill_in "Project name", with: "P7 study project"
    fill_in "Destination country (ISO code)", with: "GB"
    fill_in "Start date", with: "2027-01-15"
    fill_in "Project currency", with: "GBP"
    click_button "Create project"

    assert_text "P7 study project"
    project = Abroa::StudyProject.for_user(user).find_by!(name: "P7 study project")
    assert_equal "GBP", project.currency
    refresh
    assert_text "P7 study project"
    save_screenshot Rails.root.join("tmp/screenshots/p7-study-project.png")
  end
end
