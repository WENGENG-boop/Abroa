require "test_helper"
require "concurrent"
require "timeout"

class Abroa::StudyAllocationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "P2 allocation concurrency", currency: "GBP", balance: 1000)
    @entry = @account.entries.create!(entryable: Transaction.new, name: "Purchase", amount: 100,
      currency: "GBP", date: Date.current)
    params = { country: "GB", name: "Program", currency: "GBP", timezone: "Europe/London", start_on: "2025-01-01" }
    @projects = [ "A", "B" ].map do |suffix|
      project = Abroa::StudyProject.create_for!(@user, attributes: params.merge(name: suffix), key: "concurrent-#{suffix}")
      Abroa::ProjectAccount.attach_for!(@user, project.id, @account.id)
      project
    end
  end

  teardown do
    Abroa::EntryAllocation.where(project_id: @projects.map(&:id)).delete_all
    Abroa::ProjectAccount.where(project_id: @projects.map(&:id)).delete_all
    @projects.each(&:destroy!)
    @account.destroy!
  end

  test "two independent database connections cannot overallocate a shared entry" do
    gate = Concurrent::CountDownLatch.new(2)
    threads = @projects.map do |project|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.count_down
          raise "Concurrency barrier timed out" unless gate.wait(10)
          Abroa::EntryAllocation.allocate_for!(User.find(@user.id), project.id, entry_id: @entry.id, amount: "70")
          :allocated
        rescue ArgumentError
          :rejected
        end
      end
    end
    result = Timeout.timeout(30) { threads.map(&:value).sort }
    assert_equal [:allocated, :rejected], result
    assert_equal BigDecimal("70"), Abroa::EntryAllocation.where(entry_id: @entry.id).sum(:amount)
    assert_equal BigDecimal("100"), @entry.reload.amount
  ensure
    threads&.each { |thread| thread.kill if thread.alive?; thread.join }
  end
end
