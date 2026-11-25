class Api::V1::Abroa::ForecastsController < Api::V1::Abroa::BaseController
  rescue_from ArgumentError, Date::Error, with: :render_invalid_input

  def show
    options = forecast_options
    selected_accounts = account_ids
    data = ::Abroa::Forecast.for_student(current_resource_owner, **options,
      account_ids: selected_accounts)
    render_json({ data: data })
  end

  def parent
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    data = ::Abroa::Forecast.for_parent!(current_resource_owner, params[:id], **forecast_options)
    render_json({ data: data })
  end

  private
    def account_ids
      return nil if params[:account_ids].nil?
      ids = params[:account_ids]
      raise ArgumentError, "Expected a list of account IDs" unless ids.is_a?(Array) &&
        ids.any? && ids.size <= 100 && ids.all? { |id| valid_uuid?(id) }
      ids
    end

    def forecast_options
      options = {}
      options[:project_id] = validated_project_id if params[:project_id].present? && action_name == "show"
      options[:currency] = params[:currency] if params[:currency].present?
      options[:scenario] = params[:scenario] if params[:scenario].present?
      %i[living_multiplier rent_multiplier fx_shock_pct].each do |key|
        options[key] = params[key] if params[key].present?
      end
      if params[:funding_delay_days].present?
        raw = params[:funding_delay_days]
        raise ArgumentError, "Invalid funding delay" unless raw.to_s.match?(/\A\d{1,3}\z/)
        options[:funding_delay_days] = raw.to_i
      end
      if action_name == "show" && params.key?(:timeline)
        raise ArgumentError, "Expected true or false" unless %w[true false].include?(params[:timeline])
        options[:include_timeline] = params[:timeline] == "true"
      end
      options
    end

    def validated_project_id
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      params[:project_id]
    end
end
