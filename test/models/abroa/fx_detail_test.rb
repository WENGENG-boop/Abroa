require "test_helper"

class Abroa::FxDetailTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @source = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "CNY account", currency: "CNY", balance: 20_000)
    @target = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "GBP account", currency: "GBP", balance: 0)
    @params = { source_account_id: @source.id, destination_account_id: @target.id,
      date: Date.current, debit_amount: "9000", credit_amount: "1000",
      fee_amount: "100", fee_currency: "CNY", idempotency_key: "exchange-1" }
  end

  test "actual exchange keeps the fee separate from principal and replays only once" do
    detail = nil
    assert_difference({ "Transfer.count" => 1, "Entry.count" => 3, "Abroa::FxDetail.count" => 1 }) do
      detail = Abroa::FxDetail.create_for!(@user, **@params)
    end
    assert_equal BigDecimal("9000"), detail.debit_entry.amount
    assert_equal BigDecimal("-1000"), detail.credit_entry.amount
    assert_equal BigDecimal("100"), detail.fee_entry.amount
    assert_equal "CNY", detail.fee_currency
    assert_equal (BigDecimal("1000") / BigDecimal("9000")).round(16), detail.actual_rate
    assert detail.consistent?
    assert_equal "funds_movement", detail.debit_entry.transaction.kind
    assert_equal "standard", detail.fee_entry.transaction.kind
    assert_no_difference [ "Entry.count", "Transfer.count", "Abroa::FxDetail.count" ] do
      assert_equal detail.id, Abroa::FxDetail.create_for!(@user, **@params).id
    end
    assert_raises(Abroa::FxDetail::Conflict) do
      Abroa::FxDetail.create_for!(@user, **@params.merge(credit_amount: "1001"))
    end
  end

  test "cross-tenant and unauthorized accounts cannot be used" do
    outsider = users(:empty)
    assert_no_difference "Entry.count" do
      assert_raises(ActiveRecord::RecordNotFound) { Abroa::FxDetail.create_for!(outsider, **@params) }
    end
  end

  test "invalid fee currency and nonfinite amount never post ledger entries" do
    assert_no_difference "Entry.count" do
      assert_raises(ArgumentError) { Abroa::FxDetail.create_for!(@user, **@params.merge(fee_currency: "USD")) }
      assert_raises(ArgumentError) { Abroa::FxDetail.create_for!(@user, **@params.merge(debit_amount: "NaN")) }
    end
  end
end
