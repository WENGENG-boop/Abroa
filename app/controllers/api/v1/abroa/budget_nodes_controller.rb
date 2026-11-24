class Api::V1::Abroa::BudgetNodesController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update adjust rollover]
  rescue_from ::Abroa::BudgetNode::Conflict, ::Abroa::OperationRecord::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(project.budget_nodes, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: budget.payload })
  end

  def create
    fields = body_fields!(*::Abroa::BudgetNode::FIELDS)
    record = ::Abroa::BudgetNode.create_for!(Current.user, project.id,
      attributes: fields, key: require_idempotency_key!)
    render_json({ data: record.payload }, status: :created)
  end

  def update
    fields = body_fields!(*::Abroa::BudgetNode::FIELDS, :lock_version)
    version = fields.delete(:lock_version)
    record = ::Abroa::BudgetNode.change_for!(Current.user, budget.id, version: version, attributes: fields)
    render_json({ data: record.payload })
  end

  def adjust
    fields = body_fields!(:lock_version, :limit_amount, :warning_threshold)
    version = fields.delete(:lock_version)
    record = ::Abroa::BudgetNode.change_for!(Current.user, budget.id, version: version, attributes: fields)
    render_json({ data: record.payload })
  end

  def rollover
    fields = body_fields!(:target_id)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:target_id])
    record = ::Abroa::BudgetNode.rollover_for!(Current.user, budget.id,
      target_id: fields[:target_id], key: require_idempotency_key!)
    render_json({ data: record.payload })
  end

  def versions
    page = ::Abroa::Page.fetch(budget.versions, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |record| record.attributes.slice("id", "kind", "operation_key", "from_data", "to_data", "created_at") },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def execution
    result = budget.execution_for!(Current.user)
    result = result.transform_values { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value }
    render_json({ data: result })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(Current.user, params[:project_id])
    end

    def budget
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @budget ||= project.budget_nodes.find(params[:id])
    end
end
