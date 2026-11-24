require "test_helper"

class Abroa::EntryAllocationTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Shared funding", currency: "GBP", balance: 1000)
    @entry = @account.entries.create!(entryable: Transaction.new, name: "Expense", amount: 100,
      currency: "GBP", date: Date.new(2025, 3, 1))
    fields = { country: "GB", start_on: "2025-01-01", end_on: "2025-12-31", currency: "GBP", timezone: "Europe/London" }
    @a = Abroa::StudyProject.create_for!(@user, attributes: fields.merge(name: "A"), key: "project-a")
    @b = Abroa::StudyProject.create_for!(@user, attributes: fields.merge(name: "B"), key: "project-b")
    [ @a, @b ].each { |project| Abroa::ProjectAccount.attach_for!(@user, project.id, @account.id) }
  end

  test "shared account never automatically allocates entries and explicit splits conserve the ledger" do
    assert_equal 0, Abroa::EntryAllocation.count
    assert_no_difference "Entry.count" do
      first = allocate(@a, "60")
      second = allocate(@b, "30")
      assert_equal BigDecimal("60"), first.amount
      assert_equal BigDecimal("30"), second.amount
      assert_equal BigDecimal("10"), Abroa::EntryAllocation.remaining_for!(@user, @entry.id)
      assert_equal BigDecimal("100"), @entry.reload.amount
    end
    assert_raises(ArgumentError) { allocate(@b, "50", category_id: categories(:food_and_drink).id) }
  end

  test "project-specific category can change without changing the original transaction" do
    allocation = allocate(@a, "60")
    category = categories(:food_and_drink)
    changed = Abroa::EntryAllocation.change_for!(@user, @a.id, allocation.id,
      version: allocation.lock_version, category_id: category.id)
    assert_equal category.id, changed.category_id
    assert_equal BigDecimal("60"), changed.amount
    assert_nil @entry.reload.transaction.category_id
    assert_raises(Abroa::StudyProject::Conflict) do
      Abroa::EntryAllocation.change_for!(@user, @a.id, allocation.id,
        version: allocation.lock_version, category_id: nil)
    end
  end

  test "archiving retains allocations and blocks new allocation writes" do
    allocation = allocate(@a, "60")
    archived = Abroa::StudyProject.archive_for!(@user, @a.id, version: @a.reload.lock_version)
    assert_equal allocation.id, Abroa::EntryAllocation.find(allocation.id).id
    assert_raises(Abroa::StudyProject::Conflict) do
      Abroa::EntryAllocation.change_for!(@user, archived.id, allocation.id, version: allocation.lock_version, amount: "50")
    end
    assert_equal BigDecimal("100"), @entry.reload.amount
  end

  test "later ledger modification marks allocations inconsistent" do
    allocation = allocate(@a, "60")
    @entry.update!(amount: 20)
    assert_not allocation.reload.consistent?
    assert_nil Abroa::EntryAllocation.remaining_for!(@user, @entry.id)
  end

  test "a split parent is ineligible and foreign users cannot allocate" do
    @entry.stubs(:split_parent?).returns(true)
    Entry.any_instance.stubs(:split_parent?).returns(true)
    assert_raises(ArgumentError) { allocate(@a, "60") }
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::EntryAllocation.allocate_for!(users(:empty), @a.id, entry_id: @entry.id, amount: "10")
    end
  end

  private
    def allocate(project, amount, **options)
      Abroa::EntryAllocation.allocate_for!(@user, project.id, entry_id: @entry.id, amount: amount, **options)
    end
end
