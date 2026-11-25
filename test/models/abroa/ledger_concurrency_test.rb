require "test_helper"
require "concurrent"
require "timeout"

class Abroa::LedgerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Abroa concurrency fixture", currency: "GBP", balance: 1000)
  end

  teardown do
    if @account
      ids = @account.entries.pluck(:id)
      Abroa::RefundLink.where(original_entry_id: ids).delete_all
      Abroa::RefundLink.where(refund_entry_id: ids).delete_all
      Abroa::SourceRecord.where(account_id: @account.id).destroy_all
      @account.destroy!
    end
  end

  test "parallel captures of the same provider movement preserve one entry and source" do
    entry = movement(100, source: "simplefin", external_id: "parallel-source")
    outcomes = race do |_index|
      Abroa::ProviderSource.capture_existing!(Entry.find(entry.id)).id
    end
    assert_equal 1, outcomes.uniq.size
    assert_equal 1, @account.entries.count
    source = Abroa::SourceRecord.find(outcomes.first)
    assert_equal entry.id, source.entry_id
    assert_equal 1, source.observations.count
    assert_equal "linked", source.status
  end

  test "parallel refunds cannot overallocate the original purchase" do
    original = movement(100)
    refunds = [ movement(-60), movement(-60) ]
    outcomes = race do |index|
      Abroa::RefundLink.link_for!(User.find(@user.id), original_entry_id: original.id,
        refund_entry_id: refunds.fetch(index).id, applied_amount: "60", refund_amount: "60")
      :allocated
    rescue ArgumentError
      :rejected
    end
    assert_equal [ :allocated, :rejected ], outcomes.sort
    assert_equal 60, Abroa::RefundLink.active.where(original_entry_id: original.id).sum(:applied_amount)
    assert_equal 3, @account.entries.count
  end

  test "parallel provider imports create one entry for an identical external ID" do
    outcomes = race do |_index|
      Account::ProviderImportAdapter.new(Account.find(@account.id)).import_transaction(
        external_id: "parallel-import", amount: 100, currency: "GBP", date: Date.current,
        name: "Synthetic bank debit", source: "simplefin", allow_heuristic_matching: false).id
    end
    assert_equal 1, outcomes.uniq.size
    assert_equal 1, @account.entries.count
  end

  private
    def movement(amount, **attributes)
      @account.entries.create!(entryable: Transaction.new, name: "Synthetic movement", amount: amount,
        currency: "GBP", date: Date.current, **attributes)
    end

    def race
      latch = Concurrent::CountDownLatch.new(2)
      threads = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            latch.count_down
            raise "Concurrent test barrier timed out" unless latch.wait(10)
            yield index
          end
        end
      end
      Timeout.timeout(30) { threads.map(&:value) }
    ensure
      threads&.each { |thread| thread.kill if thread.alive?; thread.join }
    end
end
