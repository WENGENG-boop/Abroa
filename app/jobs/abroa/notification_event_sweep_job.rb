module Abroa
  # Routes P2's durable reminders and existing P3/Sure facts to a unified
  # idempotent notification inbox. Never copies private financial amounts.
  class NotificationEventSweepJob < ApplicationJob
    queue_as :scheduled
    sidekiq_options lock: :until_executed, on_conflict: :log

    MAX_EVENTS = 10_000

    def perform(as_of: nil)
      today = as_of ? Date.iso8601(as_of.to_s) : Date.current
      raise ArgumentError, "Invalid notification sweep date" if today > Date.current ||
        today < Date.current - 8
      sweep_reminders(today)
      sweep_audit_events(today)
      sweep_budget_warnings(today)
      sweep_cash_risks(today)
      sweep_pending_entries(today)
      sweep_failed_syncs(today)
    end

    private
      def sweep_reminders(today)
        FeeReminderEvent.where(occurred_at: (today - 3).beginning_of_day..Time.current)
          .order(:id).limit(MAX_EVENTS).find_each do |event|
          recipient = event.recipient
          next unless recipient&.active?
          emit(recipient, event.kind == "overdue" ? "fee_overdue" : "fee_due",
            event, "fee:#{event.id}")
        end
      end

      def sweep_audit_events(today)
        PlanningAuditEvent.where(occurred_at: (today - 3).beginning_of_day..Time.current)
          .order(:id).limit(MAX_EVENTS).find_each do |event|
          case event.event_type
          when /\Agrant\.(created|revoked)\z/
            grant = Grant.find_by(id: event.resource_id)
            next unless grant
            [ grant.actor, grant.relationship&.parent_user ].compact.uniq.each do |recipient|
              emit(recipient, "grant_change", grant, "audit:#{event.id}")
            end
          when /\Arelationship\.(activated|revoked)\z/
            relation = Relationship.find_by(id: event.resource_id)
            next unless relation
            [ relation.student_user, relation.parent_user ].each do |recipient|
              emit(recipient, "grant_change", relation, "audit:#{event.id}")
            end
          when /\Arelationship_invite\.(issued|accepted|rejected|revoked)\z/
            invite = RelationshipInvite.find_by(id: event.resource_id)
            next unless invite
            recipients = [ invite.inviter ]
            if invite.relationship
              recipients.concat([ invite.relationship.parent_user, invite.relationship.student_user ])
            end
            recipients.compact.uniq.each do |recipient|
              emit(recipient, "invitation", invite, "audit:#{event.id}")
            end
          when /\Afunding_plan\.(created|updated|confirmed|rejected|cancelled)\z/
            plan = FundingPlan.find_by(id: event.resource_id)
            notify_funding(plan, event.id) if plan
          when /\Afunding_(receipt|reversal)\.(matched|reversed)\z/
            scope = event.resource_type == "Abroa::FundingReceipt" ? FundingReceipt : FundingReversal
            movement = scope.find_by(id: event.resource_id)
            plan = movement&.try(:funding_plan) || movement&.try(:funding_receipt)&.funding_plan
            notify_funding(plan, event.id) if plan
          when /\Afunding_notice\.(reported|revoked)\z/
            notice = FundingNotice.find_by(id: event.resource_id)
            notify_funding(notice.funding_plan, event.id) if notice
          end
        end
      end

      def notify_funding(plan, audit_id)
        [ plan.student_user, plan.parent_user ].compact.uniq.each do |recipient|
          emit(recipient, "funding", plan, "audit:#{audit_id}")
        end
      end

      def sweep_budget_warnings(today)
        BudgetNode.where(status: "active", start_on: ..today, end_on: today..)
          .order(:id).limit(MAX_EVENTS).find_each do |node|
          student = node.project&.owner
          next unless student&.active? && !student.guest?
          begin
            projection = node.execution_for!(student)
            next if projection[:incomplete]
            next unless (projection[:warnings] & %w[overspent warning_threshold_reached]).any?
            emit(student, "budget_risk", node, "budget:risk:#{node.id}:#{today}")
          rescue ActiveRecord::RecordNotFound, ArgumentError => e
            Rails.logger.warn("Abroa budget reminder skipped (#{e.class.name})")
          end
        end
      end

      def sweep_cash_risks(today)
        StudyProject.where(status: %w[planning active])
          .where("start_on <= ? AND (end_on IS NULL OR end_on >= ?)", today, today)
          .order(:id).limit(MAX_EVENTS).find_each do |project|
          student = project.owner
          next unless student&.active? && !student.guest?
          begin
            estimate = Forecast.for_student(student, project_id: project.id,
              currency: project.currency, as_of: today)
            next if estimate[:missing].present? || estimate[:first_shortage_on].nil?
            next if Date.iso8601(estimate[:first_shortage_on]) > today + 30
            emit(student, "cash_shortfall", project, "cash:risk:#{project.id}:#{today}")
          rescue ActiveRecord::RecordNotFound, ArgumentError, ActiveRecord::RecordInvalid => e
            Rails.logger.warn("Abroa cash reminder skipped (#{e.class.name})")
          end
        end
      end

      def sweep_pending_entries(today)
        Entry.pending.where(date: (today - 7)..today).order(:id)
          .limit(MAX_EVENTS).find_each do |entry|
          recipient = entry.account&.owner
          next unless recipient&.active?
          emit(recipient, "transaction_review", entry, "pending:#{entry.id}")
        end
      end

      def sweep_failed_syncs(today)
        Sync.where(status: %w[failed stale], syncable_type: "Account")
          .where(updated_at: (today - 3).beginning_of_day..Time.current)
          .order(:id).limit(MAX_EVENTS).find_each do |sync|
          account = Account.find_by(id: sync.syncable_id)
          next unless account && account.owner&.active?
          emit(account.owner, "sync_failed", account, "sync:#{sync.id}")
        end
      end

      def emit(recipient, kind, source, key)
        return unless InboxNotification.authorized_source?(recipient, source)
        InboxNotification.emit_for!(recipient: recipient, event_kind: kind,
          source: source, event_key: key)
      rescue InboxNotification::Conflict
        Rails.logger.warn("Abroa notification event key conflict")
      end
  end
end
