module Abroa
  # Schedules safe, bounded retries from durable rows. Duplicate queue jobs
  # cannot cause duplicate delivery because EmailOutboxDeliveryJob claims
  # pending/failed rows under PostgreSQL locks and never replays "sending".
  class EmailOutboxSweepJob < ApplicationJob
    queue_as :scheduled
    sidekiq_options lock: :until_executed, on_conflict: :log

    def perform
      EmailOutbox.where(status: %w[pending failed])
        .where("next_retry_at IS NULL OR next_retry_at <= ?", Time.current)
        .order(:id).limit(2000).find_each do |record|
        EmailOutboxDeliveryJob.perform_later(record.id)
      end
    end
  end
end
