class Api::V1::Abroa::ProposalsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create submit accept reject cancel]
  rescue_from ::Abroa::Proposal::Conflict, ::Abroa::BudgetNode::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    scope = ::Abroa::Proposal.for_actor(current_resource_owner)
    if params[:status].present?
      raise ArgumentError, "Unknown proposal status" unless
        %w[draft pending accepted rejected cancelled expired].include?(params[:status])
      scope = scope.where(status: params[:status])
    end
    page = ::Abroa::Page.fetch(scope, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload_data), meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: proposal.payload_data })
  end

  def create
    fields = body_fields!(:relationship_id, :project_id, :operation, :target_id,
      :payload, :expected_version, :planning_draft_id)
    %i[relationship_id project_id target_id].each do |name|
      raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[name])
    end
    raise ActiveRecord::RecordNotFound if fields[:planning_draft_id].present? &&
      !valid_uuid?(fields[:planning_draft_id])
    record = ::Abroa::Proposal.create_for!(current_resource_owner, **fields, key: require_idempotency_key!)
    render_json({ data: record.payload_data }, status: :created)
  end

  def submit
    fields = body_fields!(:lock_version)
    record = ::Abroa::Proposal.submit_for!(current_resource_owner, proposal.id,
      version: fields[:lock_version])
    render_json({ data: record.payload_data })
  end

  def accept
    fields = body_fields!(:lock_version)
    record = ::Abroa::Proposal.accept_for!(current_resource_owner, proposal.id,
      version: fields[:lock_version])
    render_json({ data: record.payload_data })
  end

  def reject
    fields = body_fields!(:lock_version)
    record = ::Abroa::Proposal.reject_for!(current_resource_owner, proposal.id,
      version: fields[:lock_version])
    render_json({ data: record.payload_data })
  end

  def cancel
    fields = body_fields!(:lock_version)
    record = ::Abroa::Proposal.cancel_for!(current_resource_owner, proposal.id,
      version: fields[:lock_version])
    render_json({ data: record.payload_data })
  end

  private
    def proposal
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @proposal ||= ::Abroa::Proposal.for_actor(current_resource_owner).find(params[:id])
    end
end
