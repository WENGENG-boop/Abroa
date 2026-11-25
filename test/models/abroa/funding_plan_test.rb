require "test_helper"

class Abroa::FundingPlanTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @outsider = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    _invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "fund-invite")
    @relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "Tuition year", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2026-12-31"
    }, key: "fund-project")
    @account = Account.create!(family: @student.family, owner: @student, accountable: Depository.new,
      name: "Student bank", currency: "GBP", balance: 2000)
    @source = Account.create!(family: @parent.family, owner: @parent, accountable: Depository.new,
      name: "Parent bank", currency: "GBP", balance: 3000)
    @pool = Abroa::FundPool.create_for!(@student, @project.id, attributes: {
      name: "Living support", kind: "living", currency: "GBP", target_amount: "1000"
    }, key: "living-pool")
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "pool_manage", resource_kind: "fund_pool", resource_id: @pool.id,
      key: "funding-pool-explicit-grant")
  end

  test "parent creates a plan, student confirms, two posted receipts settle without cash creation" do
    before = Entry.count
    plan = create_plan
    assert_equal "planned", plan.status
    assert_equal BigDecimal("1000"), plan.planned_total
    assert_equal BigDecimal("0"), plan.received_total
    assert_equal before, Entry.count
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::FundingPlan.confirm_for!(@parent, plan.id, version: plan.lock_version,
        destination_account_id: @account.id)
    end
    plan = Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
      destination_account_id: @account.id)
    assert_equal "confirmed", plan.status
    first = posted_entry(-400, name: "Family support 1")
    second = posted_entry(-600, name: "Family support 2")
    expected_entries = Entry.count
    expected_balance = @account.reload.balance
    receipt = Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: first.id, key: "first")
    assert_equal BigDecimal("400"), receipt.applied_amount
    assert_equal "partially_received", plan.reload.status
    assert_equal receipt.id, Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: first.id,
      key: "first").id
    Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: second.id, key: "second")
    assert_equal "received", plan.reload.status
    assert_equal BigDecimal("1000"), plan.received_total
    assert_equal BigDecimal("0"), plan.outstanding_total
    assert_equal @pool.id, plan.fund_pool_id
    assert_equal expected_entries, Entry.count
    assert_equal expected_balance, @account.reload.balance
  end

  test "same confirmed transaction cannot be matched twice or to unrelated funding plans" do
    plan = confirmed_plan
    other = create_plan(key: "other-plan")
    other = Abroa::FundingPlan.confirm_for!(@student, other.id, version: other.lock_version,
      destination_account_id: @account.id)
    receipt = posted_entry(-400)
    Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: receipt.id, key: "match")
    assert_raises(Abroa::FundingReceipt::Conflict, ActiveRecord::RecordNotUnique) do
      Abroa::FundingReceipt.match_for!(@student, other.id, entry_id: receipt.id, key: "match-again")
    end
    assert_equal BigDecimal("400"), plan.reload.received_total
    assert_equal BigDecimal("0"), other.reload.received_total
  end

  test "outflows, pending, foreign family, wrong account and overpayment cannot match" do
    plan = confirmed_plan
    wrong = @student.family.accounts.create!(owner: @student, accountable: Depository.new,
      name: "Other student bank", currency: "GBP", balance: 1000)
    outgoing = posted_entry(200, name: "Expense")
    assert_raises(ArgumentError) do
      Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: outgoing.id, key: "outflow")
    end
    other_account_entry = wrong.entries.create!(entryable: Transaction.new, name: "Another bank",
      amount: -100, currency: "GBP", date: Date.new(2025, 2, 10))
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: other_account_entry.id, key: "wrong")
    end
    foreign = @source.entries.create!(entryable: Transaction.new, name: "Parent's cash",
      amount: -100, currency: "GBP", date: Date.new(2025, 2, 10))
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: foreign.id, key: "foreign")
    end
    too_much = posted_entry(-1500, name: "Above plan")
    assert_raises(Abroa::FundingReceipt::Conflict) do
      Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: too_much.id, key: "above")
    end
  end

  test "historical USD to GBP matching remains stable after FX correction" do
    usd = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Dollar account", currency: "USD", balance: 2000)
    plan = create_plan(amount: "400", currency: "GBP", key: "fx")
    plan = Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
      destination_account_id: usd.id)
    rate = ExchangeRate.create!(from_currency: "USD", to_currency: "GBP",
      date: Date.new(2025, 1, 10), rate: BigDecimal("0.8"))
    entry = usd.entries.create!(entryable: Transaction.new, name: "Overseas support",
      amount: -500, currency: "USD", date: Date.new(2025, 1, 10))
    match = Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: entry.id, key: "fx-match")
    assert_equal BigDecimal("400"), match.applied_amount
    assert_equal "USD", match.native_currency
    assert_equal BigDecimal("0.8"), match.rate_snapshot.rate
    rate.update!(rate: BigDecimal("0.9"))
    assert_equal BigDecimal("400"), plan.reload.received_total
    assert_equal "received", plan.status
  end

  test "partial bank refund reverses historic matched value and cannot be repeated" do
    plan = confirmed_plan
    inflow = posted_entry(-400, name: "Support")
    receipt = Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: inflow.id, key: "inflow")
    refund = posted_entry(100, name: "Support returned")
    count = Entry.count
    reversed = Abroa::FundingReversal.reverse_for!(@student, receipt.id, entry_id: refund.id, key: "return-1")
    assert_equal BigDecimal("100"), reversed.applied_amount
    assert_equal BigDecimal("300"), plan.reload.received_total
    assert_equal "partially_received", plan.status
    assert_equal reversed.id, Abroa::FundingReversal.reverse_for!(@student, receipt.id,
      entry_id: refund.id, key: "return-1").id
    assert_equal count, Entry.count
    assert_raises(Abroa::FundingReversal::Conflict) do
      Abroa::FundingReversal.reverse_for!(@student, receipt.id, entry_id: refund.id, key: "other")
    end
  end

  test "mutated source ledger fact invalidates previously confirmed funding projection" do
    plan = confirmed_plan
    original = posted_entry(-400)
    receipt = Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: original.id, key: "immutable-evidence")
    assert receipt.consistent?
    original.update!(amount: -300)
    assert_not receipt.reload.consistent?
    projection = plan.reload.payload_for(@student)
    assert_equal true, projection[:incomplete]
    assert_nil projection[:received_amount]
    assert_nil projection[:outstanding_amount]
    assert_raises(Abroa::FundingPlan::Conflict) { plan.received_total }
  end

  test "changed refund ledger evidence invalidates all resulting funding projections" do
    plan = confirmed_plan
    incoming = posted_entry(-400, name: "Support incoming")
    receipt = Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: incoming.id, key: "changed-refund-receipt")
    refund = posted_entry(100, name: "Initial bank refund")
    reversal = Abroa::FundingReversal.reverse_for!(@student, receipt.id,
      entry_id: refund.id, key: "changed-refund-match")
    assert reversal.consistent?
    refund.update!(amount: 150)
    assert_not reversal.reload.consistent?
    assert_not plan.reload.evidence_consistent?
    assert_equal true, plan.payload_for(@student)[:incomplete]
    assert_nil plan.payload_for(@student)[:received_amount]
  end

  test "student can propose a funding adjustment without changing the parent's plan until accepted" do
    before_entries = Entry.count
    plan = create_plan
    suggestion = Abroa::FundingSuggestion.create_for!(@student, plan.id,
      attributes: { amount: "800", name: "Reduced support" }, key: "student-suggest-800")
    assert_equal "pending", suggestion.status
    assert_equal BigDecimal("1000"), plan.reload.amount
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::FundingSuggestion.accept_for!(@student, suggestion.id, version: suggestion.lock_version)
    end
    accepted = Abroa::FundingSuggestion.accept_for!(@parent, suggestion.id,
      version: suggestion.lock_version)
    assert_equal "accepted", accepted.status
    assert_equal BigDecimal("800"), plan.reload.amount
    assert_equal "Reduced support", plan.name
    assert_equal before_entries, Entry.count
    assert_equal accepted.id, Abroa::FundingSuggestion.accept_for!(@parent, suggestion.id,
      version: suggestion.lock_version).id
  end

  test "funding suggestions respect optimistic version and relationship revocation" do
    plan = create_plan
    suggestion = Abroa::FundingSuggestion.create_for!(@student, plan.id,
      attributes: { amount: "700" }, key: "student-700")
    Abroa::FundingPlan.change_for!(@parent, plan.id, version: plan.lock_version,
      attributes: { amount: "900" })
    assert_raises(Abroa::FundingSuggestion::Conflict) do
      Abroa::FundingSuggestion.accept_for!(@parent, suggestion.id, version: suggestion.lock_version)
    end
    assert_equal BigDecimal("900"), plan.reload.amount
    Abroa::FundingSuggestion.cancel_for!(@student, suggestion.id, version: suggestion.lock_version)
    another = Abroa::FundingSuggestion.create_for!(@student, plan.id,
      attributes: { amount: "600" }, key: "student-600")
    Abroa::Relationship.revoke_for!(@student, @relation.id, version: @relation.lock_version)
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::FundingSuggestion.accept_for!(@parent, another.id, version: another.lock_version)
    end
  end

  test "monthly recurrence has deterministic total, installment dates, and cancels without altering received history" do
    plan = create_plan(amount: "100", frequency: "monthly",
      scheduled_on: "2025-01-10", ends_on: "2025-03-10", key: "monthly")
    assert_equal BigDecimal("300"), plan.planned_total
    assert_equal [ Date.new(2025, 1, 10), Date.new(2025, 2, 10), Date.new(2025, 3, 10) ],
      plan.schedule_dates
    plan = Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
      destination_account_id: @account.id)
    inflow = posted_entry(-100, name: "January")
    Abroa::FundingReceipt.match_for!(@student, plan.id,
      entry_id: inflow.id, due_on: Date.new(2025, 1, 10), key: "jan")
    assert_equal BigDecimal("200"), plan.reload.outstanding_total
    Abroa::FundingPlan.cancel_for!(@parent, plan.id, version: plan.lock_version)
    assert_equal "cancelled", plan.reload.status
    assert_equal BigDecimal("100"), plan.received_total
    assert_equal BigDecimal("0"), plan.outstanding_total
  end

  test "relationship revoke immediately hides funding plans and all parent projections" do
    plan = confirmed_plan
    assert_equal plan.id, Abroa::FundingPlan.for_actor(@parent).find(plan.id).id
    Abroa::Relationship.revoke_for!(@student, @relation.id, version: @relation.lock_version)
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::FundingPlan.for_actor(@parent).find(plan.id) }
    assert_raises(ActiveRecord::RecordNotFound) { plan.reload.payload_for(@parent) }
    assert_equal plan.id, Abroa::FundingPlan.for_student(@student).find(plan.id).id
  end

  test "parent never sees student account IDs or individual transaction and cannot match receipts" do
    plan = confirmed_plan
    inflow = posted_entry(-200)
    Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: inflow.id, key: "privacy")
    parent_payload = plan.reload.payload_for(@parent)
    assert_equal "200.0", parent_payload[:received_amount]
    assert_not_includes parent_payload.to_json, @account.id
    assert_not_includes parent_payload.to_json, inflow.id
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::FundingReceipt.match_for!(@parent, plan.id, entry_id: inflow.id, key: "parent-no-match")
    end
    Abroa::Relationship.revoke_for!(@student, @relation.id, version: @relation.lock_version)
    assert_raises(ActiveRecord::RecordNotFound) { plan.reload.payload_for(@parent) }
  end

  private
    def create_plan(amount: "1000", currency: "GBP", frequency: "once",
      scheduled_on: "2025-02-10", ends_on: nil, key: "plan-1")
      Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
        project_id: @project.id, attributes: { name: "Living allowance",
          amount: amount, currency: currency, frequency: frequency, scheduled_on: scheduled_on,
          ends_on: ends_on, fund_pool_id: @pool.id, source_account_id: @source.id },
        key: key)
    end

    def confirmed_plan
      plan = create_plan
      Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
        destination_account_id: @account.id)
    end

    def posted_entry(amount, name: "Family transfer")
      @account.entries.create!(entryable: Transaction.new, name: name, amount: amount,
        currency: "GBP", date: Date.new(2025, 2, 10))
    end
end
