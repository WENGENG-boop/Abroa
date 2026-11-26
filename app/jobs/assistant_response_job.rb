class AssistantResponseJob < ApplicationJob
  queue_as :ai_high_priority

  def perform(message, assistant_message = nil)
    # User-scoped queued AI work must not run after platform suspension.
    # Check at execution time, not only when the request was enqueued.
    user = message.chat.user
    return unless user&.active?

    ChatReservation.while_chat_runs { message.request_response(assistant_message: assistant_message) }
  ensure
    # Do not mutate a suspended user's chat after a revoked job is skipped.
    message.chat.hold_reservation if user&.active?
  end
end
