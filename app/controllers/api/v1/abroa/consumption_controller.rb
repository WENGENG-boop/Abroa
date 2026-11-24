class Api::V1::Abroa::ConsumptionController < Api::V1::Abroa::BaseController
  rescue_from ArgumentError, with: :render_invalid_input

  def show
    start_on = parse_date(params[:start_on])
    end_on = parse_date(params[:end_on])
    raise ArgumentError, "start_on and end_on must be YYYY-MM-DD" unless start_on && end_on
    result = ::Abroa::NetConsumption.for_user(Current.user, start_on: start_on, end_on: end_on,
      currency: params[:currency], account_ids: params[:account_ids])
    render_json({ data: result })
  end
end
