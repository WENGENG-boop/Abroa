module Abroa
  # Runs after Sure's nightly occurrence generator. The real Sure recurring
  # stream remains authoritative: importing a due date never posts an Entry.
  class SyncRecurringFeesJob < ApplicationJob
    queue_as :scheduled
    sidekiq_options lock: :until_executed, on_conflict: :log

    LOOKBACK_DAYS = 30
    LOOKAHEAD_DAYS = 90

    def perform(fee_plan_id = nil, as_of: nil)
      return fan_out if fee_plan_id.nil?

      plan = FeePlan.includes(:project, :recurring_transaction).find_by(id: fee_plan_id)
      return unless plan && plan.status == "active" && plan.recurring_transaction_id
      return unless plan.project.status.in?(%w[planning active])
      return if plan.family.recurring_transactions_disabled?

      # The background task acts only for the project's current owner. It uses
      # the same authorization checks as manual imports; a revoked account
      # share must not become a privileged worker bypass.
      user = plan.project.owner
      return unless user&.active? && !user.guest?
      today = as_of ? Date.iso8601(as_of.to_s) : Time.current.in_time_zone(plan.project.timezone).to_date
      start_on = [ today - LOOKBACK_DAYS, plan.project.start_on ].max
      end_on = [ today + LOOKAHEAD_DAYS, plan.project.end_on ].compact.min
      return if end_on < start_on

      FeeInstallment.import_recurring_for!(user, plan.id,
        from_on: start_on.iso8601, through_on: end_on.iso8601)
    end

    private
      def fan_out
        FeePlan.where(status: "active").where.not(recurring_transaction_id: nil)
          .find_each do |plan|
          next unless plan.project.status.in?(%w[planning active])
          next if plan.family.recurring_transactions_disabled?

          self.class.perform_later(plan.id)
        end
    end
  end
end
