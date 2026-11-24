require "test_helper"

class Abroa::RefundLinkTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Refund account", currency: "CNY", balance: 1000)
    @original = entry("Purchase", 100, Date.new(2025, 1, 10))
    @refund = entry("Refund", -30, Date.new(2025, 2, 1))
  end

  test "partial refund links existing entries without changing ledger and replays" do
    result = nil
    assert_no_difference "Entry.count" do
      assert_difference "Abroa::RefundLink.count", 1 do
        result = link(@original, @refund, "30", "30")
      end
      assert_equal result.id, link(@original, @refund, "30", "30").id
    end
    assert_equal BigDecimal("70"), result.remaining_original_amount
    assert_equal BigDecimal("100"), @original.reload.amount
    assert_equal BigDecimal("-30"), @refund.reload.amount
    assert_equal Date.new(2025, 2, 1), result.refund_date
  end

  test "several partial refunds cannot exceed original or refund entry amount" do
    link(@original, @refund, "30", "30")
    another = entry("Second refund", -80, Date.new(2025, 2, 2))
    assert_raises(ArgumentError) { link(@original, another, "80", "80") }
    assert_raises(ArgumentError) { link(@original, another, "70", "81") }
    assert_equal BigDecimal("70"), link(@original, another, "70", "70").applied_amount
  end

  test "invalid direction or date and foreign tenant are rejected" do
    assert_raises(ArgumentError) { link(@refund, @original, "10", "10") }
    early = entry("Early credit", -10, Date.new(2025, 1, 1))
    assert_raises(ArgumentError) { link(@original, early, "10", "10") }
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::RefundLink.link_for!(users(:empty), original_entry_id: @original.id,
        refund_entry_id: @refund.id, applied_amount: "30", refund_amount: "30")
    end
  end

  test "unlink is audited and never removes the real refund entry" do
    result = link(@original, @refund, "30", "30")
    assert_no_difference "Entry.count" do
      Abroa::RefundLink.unlink_for!(@user, result.id)
    end
    assert result.reload.revoked_at.present?
    assert_equal BigDecimal("100"), result.remaining_original_amount
    assert_raises(Abroa::RefundLink::Conflict) { link(@original, @refund, "30", "30") }
  end

  test "later edit makes refund projection incomplete instead of returning a stale value" do
    result = link(@original, @refund, "30", "30")
    assert result.consistent?
    @refund.update!(amount: -10)
    assert_not result.reload.consistent?
  end

  private
    def entry(name, amount, date)
      @account.entries.create!(entryable: Transaction.new, name: name, amount: amount, date: date, currency: "CNY")
    end

    def link(original, refund, amount, refund_amount)
      Abroa::RefundLink.link_for!(@user, original_entry_id: original.id, refund_entry_id: refund.id,
        applied_amount: amount, refund_amount: refund_amount)
    end
end
