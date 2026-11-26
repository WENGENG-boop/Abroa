module Abroa
  class ProjectsController < ApplicationController
    before_action :disable_project_cache
    before_action :require_project_writer, only: %i[new create]

    def index
      page = Page.fetch(StudyProject.for_user(Current.user), cursor: params[:cursor])
      @projects = page.fetch(:rows)
      @next_cursor = page[:next_cursor]
    rescue ArgumentError
      head :unprocessable_entity
    end

    def show
      @project = StudyProject.find_for!(Current.user, params[:id])
    end

    def new
      @project = StudyProject.new(timezone: Time.zone.name, currency: Current.family.currency)
      @idempotency_key = SecureRandom.uuid
    end

    def create
      attributes = params.require(:project).permit(*StudyProject::FIELDS).to_h.symbolize_keys
      @idempotency_key = params[:idempotency_key].to_s
      @project = StudyProject.create_for!(Current.user, attributes: attributes, key: @idempotency_key)
      redirect_to abroa_project_path(@project), notice: t("abroa.projects.created"), status: :see_other
    rescue ActiveRecord::RecordInvalid, ArgumentError, StudyProject::Conflict
      @project = StudyProject.new(attributes || {})
      @idempotency_key = SecureRandom.uuid
      flash.now[:alert] = t("abroa.projects.save_error")
      render :new, status: :unprocessable_entity
    end

    private
      def disable_project_cache
        response.headers["Cache-Control"] = "no-store, private"
      end

      def require_project_writer
        head :forbidden if Current.user.guest?
      end
  end
end
