module Abroa
  class ProviderCaptureJob < ApplicationJob
    queue_as :low_priority

    # Only previously committed ledger rows are inspected. No credentials,
    # remote requests or user impersonation are used by this maintenance job.
    def perform(sync_id, after_id = nil)
      sync = Sync.find_by(id: sync_id, syncable_type: "Account", status: "completed")
      return unless sync && sync.completed_at && !sync.cancel_requested_at?

      account = Account.find_by(id: sync.syncable_id)
      return unless account && !account.pending_deletion?

      # Include the upstream provider phase, which can write entries before
      # the account-level balance job starts. Older history is available via
      # the explicit bounded capture endpoint.
      start = [ sync.created_at, sync.parent&.created_at ].compact.min - 1.day
      finish = sync.completed_at
      result = ProviderCapture.capture_sync_page!(account: account, updated_from: start,
        updated_through: finish, after_id: after_id)
      if result && result[:next_cursor]
        self.class.perform_later(sync_id, result[:next_cursor])
      end
    end
  end
end
