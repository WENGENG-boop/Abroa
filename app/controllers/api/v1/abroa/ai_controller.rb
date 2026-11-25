class Api::V1::Abroa::AiController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create_provider update_provider
    create_proposal confirm_proposal reject_proposal execute_proposal compensate_proposal]
  rescue_from ::Abroa::AiModelProvider::Conflict,
    ::Abroa::AiOperationProposal::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def provider
    configured = ::Abroa::AiModelProvider.for_user(current_resource_owner).first
    render_json({ data: configured ? configured.payload.merge(configured: true) : { configured: false } })
  end

  def create_provider
    attributes = body_fields!(:base_url, :api_key, :model_name, :capabilities)
    row = ::Abroa::AiModelProvider.configure_for!(current_resource_owner,
      attributes: attributes, key: require_idempotency_key!)
    render_json({ data: row.payload }, status: :created)
  end

  def update_provider
    attributes = body_fields!(:base_url, :api_key, :model_name, :capabilities,
      :disabled, :lock_version)
    version = attributes.delete(:lock_version)
    row = ::Abroa::AiModelProvider.for_user(current_resource_owner).first!
    row.update_for!(current_resource_owner, version: version, attributes: attributes)
    render_json({ data: row.payload })
  end

  def chat
    attrs = body_fields!(:question, :project_id, :parent_project_id)
    response = ::Abroa::AiFinancialAssistant.answer_for!(current_resource_owner, **attrs)
    render_json({ data: response })
  end

  def classify
    attrs = body_fields!(:entry_id)
    result = ::Abroa::AiFinancialAssistant.classification_hint_for!(
      current_resource_owner, **attrs)
    render_json({ data: result })
  end

  def usage
    data = ::Abroa::AiModelUsage.summary_for(current_resource_owner)
    render_json({ data: data })
  end

  def proposals
    scope = ::Abroa::AiOperationProposal.for_user(current_resource_owner)
    page = ::Abroa::Page.fetch(scope, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def create_proposal
    attrs = body_fields!(:operation, :resource_id, :parameters)
    proposal, token = ::Abroa::AiOperationProposal.propose_for!(current_resource_owner,
      **attrs, key: require_idempotency_key!)
    render_json({ data: proposal.payload, confirmation_token: token }, status: :created)
  end

  def confirm_proposal
    attrs = body_fields!(:token, :lock_version)
    proposal = ::Abroa::AiOperationProposal.confirm_for!(current_resource_owner,
      validated_proposal_id, token: attrs[:token], version: attrs[:lock_version])
    render_json({ data: proposal.payload })
  end

  def reject_proposal
    body_fields!
    proposal = ::Abroa::AiOperationProposal.for_user(current_resource_owner)
      .find(validated_proposal_id)
    proposal.reject_for!(current_resource_owner)
    render_json({ data: proposal.payload })
  end

  def execute_proposal
    body_fields!
    proposal = ::Abroa::AiOperationProposal.execute_for!(current_resource_owner,
      validated_proposal_id)
    render_json({ data: proposal.payload })
  end

  def compensate_proposal
    body_fields!
    proposal = ::Abroa::AiOperationProposal.compensate_for!(current_resource_owner,
      validated_proposal_id)
    render_json({ data: proposal.payload })
  end

  private
    def validated_proposal_id
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      params[:id]
    end
end
