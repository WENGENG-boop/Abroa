require "test_helper"

class Abroa::RateSnapshotTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @date = Date.new(2025, 1, 10)
    ExchangeRate.where(from_currency: %w[USD GBP], to_currency: %w[GBP USD]).delete_all
  end

  test "historical snapshot remains unchanged when stored rate is corrected" do
    rate = ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", date: @date, rate: BigDecimal("0.8"))
    quote = Abroa::RateSnapshot.quote(from: "USD", to: "GBP", date: @date)
    assert_equal "exact", quote.quality
    assert_equal BigDecimal("80"), quote.convert("100")

    snapshot = quote.capture!(family: @user.family)
    rate.update!(rate: BigDecimal("0.9"))
    assert_equal BigDecimal("80"), snapshot.reload.convert("100")
    assert_equal BigDecimal("90"), Abroa::RateSnapshot.quote(from: "USD", to: "GBP", date: @date).convert("100")
    assert_raises(ActiveRecord::ReadOnlyRecord) { snapshot.update!(rate: 1) }
  end

  test "historical fallback is bounded and never uses a future rate" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", date: @date - 3, rate: BigDecimal("0.8"))
    ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", date: @date + 1, rate: BigDecimal("1.2"))
    quote = Abroa::RateSnapshot.quote(from: "USD", to: "GBP", date: @date, lookback_days: 5)
    assert_equal @date - 3, quote.rate_date
    assert_equal "historical_fallback", quote.quality

    missing = Abroa::RateSnapshot.quote(from: "USD", to: "GBP", date: @date, lookback_days: 2)
    assert missing.missing?
    assert_nil missing.convert("100")
    assert_raises(Abroa::RateSnapshot::MissingRate) { missing.capture!(family: @user.family) }
  end

  test "same currency is exact parity and rounds only for display" do
    quote = Abroa::RateSnapshot.quote(from: "JPY", to: "JPY", date: @date)
    assert_equal "parity", quote.quality
    assert_equal BigDecimal("12.5"), quote.convert("12.5")
    assert_equal BigDecimal("13"), quote.convert("12.5", display: true)
    assert_raises(ArgumentError) { quote.convert("not money") }
  end
end
