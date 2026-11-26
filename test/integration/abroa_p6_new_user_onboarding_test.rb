require "test_helper"

class AbroaP6NewUserOnboardingTest < ActionDispatch::IntegrationTest
  setup do
    @device = { device_id: "p6-fresh-iphone-0001", device_name: "P6 Test iPhone",
      device_type: "ios", os_version: "17.0", app_version: "1.0.0" }
    Doorkeeper::Application.find_or_create_by!(name: "Sure Mobile") do |application|
      application.redirect_uri = "sureapp://oauth/callback"
      application.scopes = "read read_write"
      application.confidential = false
    end.update!(scopes: "read read_write")
    MobileDevice.instance_variable_set(:@shared_oauth_application, nil)
  end

  test "genuinely new student signs up, logs in, completes onboarding, creates first project and stays isolated" do
    email = "abroa-p6-fresh-student@example.com"
    password = "P6SecurePassword!2026"
    before = [ User.count, Family.count, MobileDevice.count, Doorkeeper::AccessToken.count ]
    post "/api/v1/auth/signup", params: {
      user: { email: email, password: password, first_name: "P6", last_name: "Student" },
      device: @device
    }, as: :json
    assert_response :created
    first = response.parsed_body
    user = User.find(first.dig("user", "id"))
    assert_equal email, user.email
    assert_not_nil first["access_token"]
    assert_not_nil first["refresh_token"]
    assert_equal [ before[0] + 1, before[1] + 1, before[2] + 1, before[3] + 1 ],
      [ User.count, Family.count, MobileDevice.count, Doorkeeper::AccessToken.count ]
    assert_equal user.family_id, MobileDevice.find_by!(user_id: user.id, device_id: @device.fetch(:device_id)).user.family_id

    post "/api/v1/auth/login", params: {
      email: email, password: password, device: @device
    }, as: :json
    assert_response :ok
    token = response.parsed_body.fetch("access_token")
    headers = { "Authorization" => "Bearer #{token}" }
    get "/api/v1/abroa/onboarding", headers: headers
    assert_response :ok
    assert_equal "role", response.parsed_body.dig("data", "step")
    assert_equal 0, response.parsed_body.dig("data", "lock_version")

    patch "/api/v1/abroa/profile", params: {
      student_enabled: true, parent_enabled: false, origin_country: "CN",
      residence_country: "GB", display_currency: "GBP", timezone: "Europe/London",
      mode: "simple", lock_version: 0
    }, as: :json, headers: headers
    assert_response :ok
    assert_equal 1, response.parsed_body.dig("data", "lock_version")
    assert_equal "GBP", user.reload.abroa_profile.display_currency if user.respond_to?(:abroa_profile)
    assert_equal "GBP", Abroa::Profile.find_by!(user: user).display_currency

    patch "/api/v1/abroa/onboarding",
      params: { step: "review", lock_version: 1 }, as: :json, headers: headers
    assert_response :ok
    assert_equal 2, response.parsed_body.dig("data", "lock_version")
    assert_nil Abroa::Profile.find_by!(user: user).completed_at

    headers_with_key = headers.merge("Idempotency-Key" => "p6-first-onboarding-completion")
    post "/api/v1/abroa/onboarding/complete",
      params: { lock_version: 2 }, as: :json, headers: headers_with_key
    assert_response :ok
    first_completion = response.parsed_body.dig("data")
    assert_equal "complete", first_completion.fetch("step")
    assert_not_nil Abroa::Profile.find_by!(user: user).completed_at
    post "/api/v1/abroa/onboarding/complete",
      params: { lock_version: 2 }, as: :json, headers: headers_with_key
    assert_response :ok
    assert_equal first_completion, response.parsed_body.dig("data")

    assert_difference("Abroa::StudyProject.count", 1) do
      post "/api/v1/abroa/projects", params: {
        name: "First P6 British Tuition Project", country: "GB", origin_country: "CN",
        currency: "GBP", timezone: "Europe/London",
        start_on: "2026-09-01", end_on: "2027-08-31"
      }, as: :json, headers: headers.merge("Idempotency-Key" => "p6-first-project")
      assert_response :created
    end
    project_id = response.parsed_body.dig("data", "id")
    project = Abroa::StudyProject.find(project_id)
    assert_equal user.family_id, project.family_id
    assert_equal user.id, project.owner_id
    assert_equal "GBP", project.currency

    # A different household's valid API key cannot see the newly created student's project.
    outsider = users(:empty)
    outsider_key = ApiKey.create!(user: outsider, name: "P6 external student",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    get "/api/v1/abroa/projects/#{project.id}", headers: api_headers(outsider_key)
    assert_response :not_found
    get "/api/v1/abroa/projects/#{project.id}", headers: headers
    assert_response :ok
  end
end
