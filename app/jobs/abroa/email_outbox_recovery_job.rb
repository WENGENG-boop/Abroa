module Abroa
  # Treat abandoned "sending" as uncertain rather than replaying: a worker
  # may have crashed after the SMTP provider accepted the message.
  class EmailOutboxRecoveryJob < ApplicationJob
    queue_as :scheduled
    sidekiq_options lock: :until_executed, on_conflict: :log
    STALE_AFTER = 20.minutes

    def perform
      EmailOutbox.where(status: "sending")
        .where("updated_at < ?", STALE_AFTER.ago)
        .order(:id).limit(2000).find_each do |outbox|
        outbox.with_lock do
          if outbox.status == "sending" && outbox.updated_at < STALE_AFTER.ago
            outbox.update!(status: "uncertain", error_code: "unconfirmed_worker_exit")
          end
        end
      end
    end
  end
end
