require "test_helper"

class Abroa::PlatformJobRevocationTest < ActiveJob::TestCase
  setup do
    @user = users(:family_admin)
  end

  test "queued assistant response never calls a provider for suspended users" do
    message = mock("queued user message")
    chat = mock("chat")
    message.stubs(:chat).returns(chat)
    chat.stubs(:user).returns(@user)
    message.expects(:request_response).never
    chat.expects(:hold_reservation).never

    @user.update!(platform_suspended_at: Time.current)
    assert_nil AssistantResponseJob.new.perform(message)
  end

  test "active user assistant response uses existing reservation flow" do
    message = mock("queued user message")
    chat = mock("chat")
    message.stubs(:chat).returns(chat)
    chat.stubs(:user).returns(@user)
    message.expects(:request_response).once
    chat.expects(:hold_reservation).once

    assert ChatReservation.while_chat_runs { :valid }
    AssistantResponseJob.new.perform(message)
  end
end
