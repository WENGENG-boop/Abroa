require "test_helper"

class Abroa::AccountProfileTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Wallet", currency: "CNY", balance: 100)
  end

  test "account region and wallet classification do not change balance or currency" do
    profile = Abroa::AccountProfile.change_for!(@user, @account.id, country: "cn", wallet_kind: "alipay")
    assert_equal "CN", profile.country
    assert_equal "alipay", profile.wallet_kind
    assert_equal BigDecimal("100"), @account.reload.balance
    assert_equal "CNY", @account.currency
  end

  test "unrelated tenant cannot read or update account profile" do
    outsider = users(:empty)
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::AccountProfile.for_user(outsider, @account.id) }
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::AccountProfile.change_for!(outsider, @account.id, country: "JP") }
  end

  test "credit card cannot be marked as a stored-value wallet" do
    card = Account.create!(family: @user.family, owner: @user, accountable: CreditCard.new,
      name: "Card", currency: "CNY", balance: 0)
    assert_raises(ActiveRecord::RecordInvalid) do
      Abroa::AccountProfile.change_for!(@user, card.id, wallet_kind: "wechat")
    end
  end

  test "region defaults are available without claiming a supported bank connection" do
    profile = Abroa::RegionConfig.resolve("JP")
    assert_equal "JPY", profile.fetch(:currency)
    assert_equal [], profile.fetch(:connection_kinds)
    assert_raises(ArgumentError) { Abroa::RegionConfig.resolve("ZZZ") }
  end
end
