class Api::V1::Abroa::StatementIntakesController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, except: :show
  rescue_from ::Abroa::StatementIntake::Conflict, ::Abroa::SourceRecord::IdentityConflict,
    ::Abroa::SourceReview::Conflict, with: :render_conflict
  rescue_from ::Abroa::StatementParser::UnsupportedFormat, ArgumentError, with: :render_invalid_input

  def show
    render_json({ data: ::Abroa::StatementIntake.visible_for!(Current.user, statement_id!).payload })
  end

  def preview
    fields = body_fields!(:source_kind, :mapping, :separator, :pdf_import_id)
    validate_fields!(fields)
    result = ::Abroa::StatementIntake.preview_for!(Current.user, statement_id: statement_id!, **fields)
    render_json({ data: result })
  end

  def publish
    fields = body_fields!(:source_kind, :mapping, :separator, :pdf_import_id, :preview_digest, :accept_invalid_rows)
    validate_fields!(fields)
    raise ArgumentError, "preview_digest is required" unless fields[:preview_digest].present?
    receipt = ::Abroa::StatementIntake.publish_for!(Current.user, statement_id: statement_id!, **fields)
    render_json({ data: receipt.payload }, status: :created)
  end

  private
    def statement_id!
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      params[:id]
    end

    def validate_fields!(fields)
      raise ArgumentError, "source_kind is required" unless fields[:source_kind].is_a?(String)
      if fields[:pdf_import_id].present? && !valid_uuid?(fields[:pdf_import_id])
        raise ActiveRecord::RecordNotFound
      end
    end
end
