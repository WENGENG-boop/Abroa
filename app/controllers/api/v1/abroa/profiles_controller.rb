class Api::V1::Abroa::ProfilesController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: :update

  def show
    render_json({ data: ::Abroa::Profile.for_user(current_resource_owner).preferences_payload })
  end

  def update
    fields = body_fields!(*::Abroa::Profile::PREFERENCE_FIELDS, :lock_version)
    profile = ::Abroa::Profile.change_for!(
      current_resource_owner, version: fields.delete(:lock_version), attributes: fields
    )
    render_json({ data: profile.preferences_payload })
  end
end
