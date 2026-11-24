class Api::V1::Abroa::BaseController < Api::V1::BaseController
  wrap_parameters false
  before_action :ensure_read_scope

  rescue_from ::Abroa::Profile::Conflict, ActiveRecord::StaleObjectError, with: :render_conflict
  rescue_from ::Abroa::Profile::InvalidInput, with: :render_invalid_input
  rescue_from ActiveRecord::RecordInvalid, with: :render_invalid_record

  private
    def ensure_write_access
      authorize_scope!(:write) && reject_guest_writes!
    end

    def require_idempotency_key!
      key = request.headers["Idempotency-Key"]
      unless key.is_a?(String) && key.present? && key.bytesize <= 128
        raise ::Abroa::Profile::InvalidInput, "Idempotency-Key must contain 1 to 128 bytes"
      end
      key
    end

    def body_fields!(*allowed)
      body = request.request_parameters
      unknown = body.keys.map(&:to_s) - allowed.map(&:to_s)
      raise ::Abroa::Profile::InvalidInput, "Unknown request field" if unknown.any?

      body.symbolize_keys
    end

    def render_json(data, status: :ok)
      if data.is_a?(Hash) && data[:error].is_a?(String)
        data = {
          error: {
            code: data[:error], message: data[:message], request_id: request.request_id
          }
        }
      end
      super(data, status: status)
    end

    def render_conflict(_error)
      render_json({ error: "conflict", message: "Resource version or request has changed" }, status: :conflict)
    end

    def render_invalid_input(error)
      render_json({ error: "validation_failed", message: error.message }, status: :unprocessable_entity)
    end

    def render_invalid_record(error)
      render_json({
        error: {
          code: "validation_failed", message: "Invalid request",
          field_errors: error.record.errors.to_hash, request_id: request.request_id
        }
      }, status: :unprocessable_entity)
    end
end
