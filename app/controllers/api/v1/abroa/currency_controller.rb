class Api::V1::Abroa::CurrencyController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: [ :update_account_profile, :create_exchange ]
  rescue_from ArgumentError, with: :render_invalid_input
  rescue_from ::Abroa::FxDetail::Conflict, Transfer::Creator::StaleIdempotencyKeyError, with: :render_conflict

  def rates
    days = params[:lookback_days]
    if days.present? && (!days.is_a?(String) || !days.match?(/\A\d{1,3}\z/))
      raise ArgumentError, "Invalid historical lookback"
    end
    quote = ::Abroa::RateSnapshot.quote(
      from: params[:from], to: params[:to], date: required_date!(params[:date]),
      lookback_days: days.present? ? days.to_i : ::Abroa::RateSnapshot::DEFAULT_LOOKBACK_DAYS
    )
    data = quote.payload
    if params.key?(:amount)
      amount = ::Abroa::Decimal.money!(params[:amount])
      data = data.merge(
        original_amount: amount.to_s("F"),
        converted_amount: quote.convert(amount)&.to_s("F"),
        display_amount: quote.convert(amount, display: true)&.to_s("F")
      )
    end
    render_json({ data: data })
  end

  def region
    render_json({ data: ::Abroa::RegionConfig.resolve(params[:country_code]) })
  end

  def account_profile
    require_uuid!(params[:account_id])
    render_json({ data: ::Abroa::AccountProfile.for_user(Current.user, params[:account_id]).payload })
  end

  def update_account_profile
    require_uuid!(params[:account_id])
    fields = body_fields!(:country, :wallet_kind, :lock_version)
    unless fields[:lock_version].is_a?(Integer) && fields[:lock_version] >= 0
      raise ArgumentError, "lock_version must be a non-negative integer"
    end
    profile = ::Abroa::AccountProfile.change_for!(Current.user, params[:account_id], **fields)
    render_json({ data: profile.payload })
  end

  def create_exchange
    fields = body_fields!(:source_account_id, :destination_account_id, :date,
      :debit_amount, :credit_amount, :fee_amount, :fee_currency)
    %i[source_account_id destination_account_id].each { |field| require_uuid!(fields[field]) }
    detail = ::Abroa::FxDetail.create_for!(
      Current.user,
      source_account_id: fields[:source_account_id], destination_account_id: fields[:destination_account_id],
      date: required_date!(fields[:date]), debit_amount: fields[:debit_amount], credit_amount: fields[:credit_amount],
      fee_amount: fields.fetch(:fee_amount, "0"), fee_currency: fields[:fee_currency],
      idempotency_key: request.headers["Idempotency-Key"]
    )
    render_json({ data: detail.payload }, status: :created)
  end

  def exchange
    require_uuid!(params[:id])
    render_json({ data: ::Abroa::FxDetail.visible_to!(Current.user, params[:id]).payload })
  end

  private
    def required_date!(value)
      parse_date(value) || raise(ArgumentError, "date must be YYYY-MM-DD")
    end

    def require_uuid!(value)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(value)
    end
end
