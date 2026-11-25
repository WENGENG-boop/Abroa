class Api::V1::Abroa::NotificationsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[read update_preferences]
  rescue_from ::Abroa::NotificationPreference::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    unless ::Abroa::NotificationPreference.for_user(current_resource_owner).in_app_enabled
      return render_json({ data: [], meta: { next_cursor: nil } })
    end
    scope = ::Abroa::InboxNotification.for_user(current_resource_owner)
    page = ::Abroa::Page.fetch(scope, limit: params[:limit], cursor: params[:cursor])
    items = page[:rows].select { |item| item.authorized_for?(current_resource_owner) }
    render_json({ data: items.map(&:payload),
      meta: { next_cursor: page[:next_cursor] } })
  end

  def read
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    item = ::Abroa::InboxNotification.for_user(current_resource_owner).find(params[:id])
    item.mark_read_for!(current_resource_owner)
    render_json({ data: item.payload })
  end

  def preferences
    render_json({ data: ::Abroa::NotificationPreference.for_user(current_resource_owner).payload })
  end

  def update_preferences
    fields = body_fields!(:lock_version, *::Abroa::NotificationPreference::FIELDS)
    version = fields.delete(:lock_version)
    pref = ::Abroa::NotificationPreference.for_user(current_resource_owner)
    pref.update_for!(current_resource_owner, attributes: fields, version: version)
    render_json({ data: pref.payload })
  end
end
