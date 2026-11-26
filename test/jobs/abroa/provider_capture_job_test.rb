require "test_helper"

class Abroa::ProviderCaptureJobTest < ActiveJob::TestCase
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Sync capture", currency: "GBP", balance: 100)
    @entry = @account.entries.create!(entryable: Transaction.new, name: "Provider payment",
      amount: 12, currency: "GBP", date: Date.current, source: "simplefin", external_id: "sync-1")
  end

  test "completed account sync captures recent existing rows idempotently" do
    sync = @account.syncs.create!(status: "completed", completed_at: Time.current)
    assert_no_difference "Entry.count" do
      assert_difference "Abroa::SourceRecord.count", 1 do
        Abroa::ProviderCaptureJob.perform_now(sync.id)
      end
      assert_no_difference "Abroa::SourceRecord.count" do
        Abroa::ProviderCaptureJob.perform_now(sync.id)
      end
    end
    assert_equal @entry.id, Abroa::SourceRecord.find_by!(account: @account).entry_id
  end

  test "suspended account owner prevents queued source record capture" do
    sync = @account.syncs.create!(status: "completed", completed_at: Time.current)
    @user.update!(platform_suspended_at: Time.current)
    assert_no_difference "Abroa::SourceRecord.count" do
      assert_no_difference "Entry.count" do
        Abroa::ProviderCaptureJob.perform_now(sync.id)
      end
    end
    assert_not @user.reload.active?
  end

  test "failed and missing syncs do not capture" do
    sync = @account.syncs.create!(status: "failed")
    assert_no_difference "Abroa::SourceRecord.count" do
      Abroa::ProviderCaptureJob.perform_now(sync.id)
      Abroa::ProviderCaptureJob.perform_now(SecureRandom.uuid)
    end
  end
end
