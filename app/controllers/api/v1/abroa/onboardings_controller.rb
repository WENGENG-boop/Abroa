class Api::V1::Abroa::OnboardingsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: [ :update, :complete ]

  def show
    render_json({ data: ::Abroa::Profile.for_user(current_resource_owner).onboarding_payload })
  end

  def update
    fields = body_fields!(:step, :lock_version)
    profile = ::Abroa::Profile.advance_for!(current_resource_owner, version: fields[:lock_version], step: fields[:step])
    render_json({ data: profile.onboarding_payload })
  end

  def complete
    fields = body_fields!(:lock_version)
    profile = ::Abroa::Profile.complete_for!(
      current_resource_owner, version: fields[:lock_version], key: request.headers["Idempotency-Key"]
    )
    render_json({ data: profile.onboarding_payload(replay: true) })
  end
end
