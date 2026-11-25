class Api::V1::Abroa::RefundLinksController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, except: :show
  rescue_from ::Abroa::RefundLink::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def show
    require_uuid!(params[:id])
    link = ::Abroa::RefundLink.visible_to!(current_resource_owner, params[:id])
    render_json({ data: public_payload(link) })
  end

  def create
    fields = body_fields!(:original_entry_id, :refund_entry_id, :applied_amount, :refund_amount, :rate_snapshot_id)
    %i[original_entry_id refund_entry_id].each { |field| require_uuid!(fields[field]) }
    require_uuid!(fields[:rate_snapshot_id]) if fields[:rate_snapshot_id].present?
    link = ::Abroa::RefundLink.link_for!(current_resource_owner, **fields)
    render_json({ data: public_payload(link) }, status: :created)
  end

  def destroy
    require_uuid!(params[:id])
    body_fields!
    link = ::Abroa::RefundLink.unlink_for!(current_resource_owner, params[:id])
    render_json({ data: public_payload(link) })
  end

  private
    def require_uuid!(value)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(value)
    end

    def public_payload(link)
      # The total remaining original amount could disclose refunds in other
      # private accounts. Expose only this explicitly authorized allocation.
      link.payload.except(:remaining_original_amount)
    end
end
