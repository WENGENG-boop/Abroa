require "test_helper"
require "concurrent"
require "timeout"

class Abroa::DebtConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @student = users(:family_admin)
    @account = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "P4 debt concurrency account", currency: "GBP", balance: 1200)
    original = @account.entries.create!(entryable: Transaction.new, name: "Shared expense",
      amount: 800, currency: "GBP", date: Date.new(2025, 2, 10))
    @debt = Abroa::PersonalDebt.create_for!(@student,
      attributes: { kind: "paid_for_other", contact_nickname: "Concurrency test",
        currency: "GBP", source_entry_id: original.id,
        personal_amount: "200", other_amount: "600", incurred_on: "2025-02-10" },
      key: "p4-debt-concurrency")
  end

  teardown do
    if @debt
      settlement_ids = Abroa::DebtSettlement.where(personal_debt_id: @debt.id).select(:id)
      Abroa::DebtSettlement.where(refunded_settlement_id: settlement_ids).delete_all
      Abroa::DebtSettlement.where(personal_debt_id: @debt.id).delete_all
      debt_account = @debt.debt_account
      @debt.destroy!
      debt_account.destroy!
    end
    @account&.destroy!
  end

  test "two PostgreSQL sessions cannot overpay one debt using distinct genuine entries" do
    entries = [ 400, 400 ].map do |amount|
      @account.entries.create!(entryable: Transaction.new, name: "Incoming cash",
        amount: -amount, currency: "GBP", date: Date.new(2025, 2, 10))
    end
    cash_balance = @account.reload.balance
    result = race(entries.each_with_index.to_a) do |entry, index|
      Abroa::DebtSettlement.settle_for!(User.find(@student.id), @debt.id,
        entry_id: entry.id, amount: "400", key: "race-#{index}").id
    end
    assert_equal 1, result.count { |value, _| value != :rejected }
    assert_equal 1, result.count { |value, _| value == :rejected }
    assert_equal 2, result.map(&:last).uniq.size, "Must use distinct PostgreSQL backends"
    assert_equal 1, @debt.settlements.count
    assert_equal BigDecimal("400"), @debt.reload.net_settled_amount
    assert_equal BigDecimal("200"), @debt.outstanding_amount
    assert_equal cash_balance, @account.reload.balance
  end

  test "duplicate simultaneous confirmation of same entry and key returns the identical immutable settlement" do
    entry = @account.entries.create!(entryable: Transaction.new, name: "Repayment",
      amount: -200, currency: "GBP", date: Date.new(2025, 2, 10))
    result = race([ 1, 2 ]) do |_|
      Abroa::DebtSettlement.settle_for!(User.find(@student.id), @debt.id,
        entry_id: entry.id, amount: "200", key: "same-confirm").id
    end
    assert_equal 1, result.map(&:first).uniq.size, "Both requests must return one settlement ID"
    assert_equal 2, result.map(&:last).uniq.size
    assert_equal 1, @debt.settlements.count
    assert_equal BigDecimal("400"), @debt.reload.outstanding_amount
  end

  private
    def race(items)
      gate = Concurrent::CountDownLatch.new(items.size)
      threads = items.map do |item|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            backend_pid = ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
            gate.count_down
            raise "Concurrent barrier expired" unless gate.wait(15)
            [ yield(item), backend_pid ]
          rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique,
            Abroa::DebtSettlement::Conflict, Abroa::PersonalDebt::Conflict
            [ :rejected, backend_pid ]
          end
        end
      end
      Timeout.timeout(45) { threads.map(&:value) }
    ensure
      threads&.each { |thread| thread.kill if thread.alive?; thread.join }
    end
end
