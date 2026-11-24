module Abroa
  # A daily sweep creates durable, deduplicated reminder events only.
  # Delivery to a user's inbox or email is the separate P4.3 stage.
  class FeeReminderSweepJob < ApplicationJob
    queue_as :scheduled
    sidekiq_options lock: :until_executed, on_conflict: :log

    DAYS_BEFORE_DUE = 3
    MAX_OVERDUE_DAYS = 365

    def perform(as_of: nil)
      today = as_of ? Date.iso8601(as_of.to_s) : Date.current
      scope = FeeInstallment.joins(:fee_plan)
        .where(state: "confirmed", abroa_fee_plans: { status: "active" })
        .where(due_on: (today - MAX_OVERDUE_DAYS)..(today + DAYS_BEFORE_DUE))
      scope.find_each do |installment|
        plan = installment.fee_plan
        project = plan.project
        next unless project.status.in?(%w[planning active])
        actor = project.owner
        next unless actor&.active? && !actor.guest?
        next unless installment.readable_for?(actor)
        next if installment.settlements.any? { |payment| !payment.consistent? }

        due = installment.recurring_occurrence
        next if due&.skipped?
        remaining = installment.outstanding_amount
        remaining = [ remaining, due.remaining_amount ].min if due
        next unless remaining.positive?
        local_today = as_of ? today : Time.current.in_time_zone(project.timezone).to_date
        next if installment.due_on > local_today + DAYS_BEFORE_DUE

        kind = installment.due_on < local_today ? "overdue" : "due_soon"
        FeeReminderEvent.emit_for!(installment, recipient: actor, kind: kind)
      end
    end
  end
end
