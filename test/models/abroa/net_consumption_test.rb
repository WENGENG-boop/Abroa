require "test_helper"

class Abroa::NetConsumptionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Consumption report", currency: "CNY", balance: 1000)
    @purchase = movement(@account, "100", Date.new(2025, 1, 10))
    @refund = movement(@account, "-30", Date.new(2025, 2, 1))
    @credit = movement(@account, "-20", Date.new(2025, 2, 2))
    @link = Abroa::RefundLink.link_for!(@user, original_entry_id: @purchase.id,
      refund_entry_id: @refund.id, applied_amount: "30", refund_amount: "30")
  end

  test "refund reduces net spending on refund date without reducing the historical purchase" do
    assert_no_difference ["Entry.count", "Abroa::RateSnapshot.count"] do
      january = report(Date.new(2025, 1, 1), Date.new(2025, 1, 31))
      february = report(Date.new(2025, 2, 1), Date.new(2025, 2, 28))
      combined = report(Date.new(2025, 1, 1), Date.new(2025, 2, 28))
      assert_equal "100.0", january.dig(:totals, :net_consumption)
      assert_equal "-30.0", february.dig(:totals, :net_consumption)
      assert_equal "20.0", february.dig(:totals, :unallocated_inflows)
      assert_equal "70.0", combined.dig(:totals, :net_consumption)
      assert_equal "100.0", combined.dig(:totals, :gross_consumption)
      assert_equal "30.0", combined.dig(:totals, :refunds)
      assert_not combined[:incomplete]
    end
  end

  test "revoking the allocation does not delete the refund movement" do
    Abroa::RefundLink.unlink_for!(@user, @link.id)
    result = report(Date.new(2025, 1, 1), Date.new(2025, 2, 28))
    assert_equal "100.0", result.dig(:totals, :net_consumption)
    assert_equal "50.0", result.dig(:totals, :unallocated_inflows)
    assert_equal BigDecimal("-30"), @refund.reload.amount
  end

  test "inconsistent allocations produce an incomplete report instead of a false net amount" do
    @refund.update!(amount: -10)
    result = report(Date.new(2025, 1, 1), Date.new(2025, 2, 28))
    assert result[:incomplete]
    assert_equal 1, result[:inconsistent_refund_count]
    assert_nil result.dig(:totals, :net_consumption)
    assert_nil result.dig(:totals, :unallocated_inflows)
  end

  test "conversion uses each movement date and reports missing rates explicitly" do
    ExchangeRate.where(from_currency: "CNY", to_currency: "GBP").delete_all
    ExchangeRate.create!(from_currency: "CNY", to_currency: "GBP", date: @purchase.date, rate: "0.1")
    result = report(Date.new(2025, 1, 1), Date.new(2025, 2, 28), currency: "GBP")
    assert result[:incomplete]
    assert_equal "10.0", result.dig(:totals, :gross_consumption)
    assert_nil result.dig(:totals, :net_consumption)
    assert_includes result[:rates].map { |rate| rate[:quality] }, "missing"
    ExchangeRate.create!(from_currency: "CNY", to_currency: "GBP", date: @refund.date, rate: "0.2")
    result = report(Date.new(2025, 1, 1), Date.new(2025, 2, 28), currency: "GBP")
    assert_not result[:incomplete]
    assert_equal "4.0", result.dig(:totals, :net_consumption)
    assert_equal "6.0", result.dig(:totals, :refunds)
    assert_equal "4.0", result.dig(:totals, :unallocated_inflows)
  end

  test "account scope excludes foreign accounts and unauthorized account requests" do
    other = users(:empty)
    foreign = Account.create!(family: other.family, owner: other, accountable: Depository.new,
      name: "Private", currency: "CNY", balance: 100)
    movement(foreign, "1000", @purchase.date)
    result = report(Date.new(2025, 1, 1), Date.new(2025, 2, 28))
    assert_equal "70.0", result.dig(:totals, :net_consumption)
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::NetConsumption.for_user(@user, account_ids: [foreign.id], start_on: @purchase.date,
        end_on: @refund.date, currency: "CNY")
    end
  end

  private
    def movement(account, amount, date)
      account.entries.create!(entryable: Transaction.new, name: "Movement", amount: amount,
        currency: account.currency, date: date)
    end

    def report(start_on, end_on, currency: "CNY")
      Abroa::NetConsumption.for_user(@user, account_ids: [@account.id],
        start_on: start_on, end_on: end_on, currency: currency)
    end
end
