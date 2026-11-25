class Api::V1::Abroa::ParentProjectsController < Api::V1::Abroa::BaseController
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(::Abroa::ParentOverview.projects_scope(current_resource_owner),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |project| ::Abroa::ParentOverview.project_data(project) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def summary
    render_json({ data: ::Abroa::ParentOverview.project_for!(current_resource_owner, resource_id) })
  end

  def budgets
    page = ::Abroa::Page.fetch(::Abroa::ParentOverview.budgets_scope!(current_resource_owner, resource_id),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |node| ::Abroa::ParentOverview.budget_data(node) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def fees
    student = ::Abroa::ParentOverview.authorized_project!(current_resource_owner, resource_id, "fees_read").owner
    page = ::Abroa::Page.fetch(::Abroa::ParentOverview.fees_scope!(current_resource_owner, resource_id),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |fee| ::Abroa::ParentOverview.fee_data(fee, student) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def pools
    page = ::Abroa::Page.fetch(::Abroa::ParentOverview.pools_scope!(current_resource_owner, resource_id),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |pool| ::Abroa::ParentOverview.pool_data(pool) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def expenses
    page = ::Abroa::Page.fetch(::Abroa::ParentOverview.expenses_scope!(current_resource_owner, resource_id),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |allocation| ::Abroa::ParentOverview.expense_data(allocation) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def funding
    page = ::Abroa::Page.fetch(::Abroa::ParentOverview.funding_scope!(current_resource_owner, resource_id),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |plan| plan.payload_for(current_resource_owner) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  private
    def resource_id
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      params[:id]
    end
end
