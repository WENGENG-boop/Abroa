require "test_helper"

class Abroa::ProjectSummaryQueryCountTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "P6 query profile", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2025-12-31" },
      key: "p6-query-profile")
    @account = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "P6 query source", balance: 1000, currency: "GBP")
    Abroa::ProjectAccount.attach_for!(@student, @project.id, @account.id)
    35.times do |index|
      entry = @account.entries.create!(entryable: Transaction.new,
        name: "P6 transaction #{index}", amount: BigDecimal("10"), currency: "GBP",
        date: Date.new(2025, 3, 1))
      Abroa::EntryAllocation.allocate_for!(@student, @project.id,
        entry_id: entry.id, amount: "10", key: "p6-profile-#{index}")
    end
  end

  test "project summary returns exact totals with observable SQL query count" do
    queries = []
    listener = ->(*args) do
      payload = args.last
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])
      next if payload[:cached]
      queries << payload[:sql]
    end
    result = nil
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      result = Abroa::ProjectSummary.for_user(@student, @project.id,
        start_on: "2025-01-01", end_on: "2025-12-31", currency: "GBP")
    end
    assert_equal false, result.fetch(:incomplete)
    assert_equal "350.0", result.fetch(:net_consumption)
    assert_equal 35, result.fetch(:allocated_entry_count)
    assert_operator queries.size, :>, 0
    puts "P6_PROJECT_SUMMARY_SQL_QUERIES=#{queries.size} FOR_ALLOCATIONS=35"
    grouped = queries.group_by { |sql| sql[/\bFROM\s+\"?([a-z0-9_]+)/i, 1] || sql.first(24) }
    puts "P6_PROJECT_SUMMARY_SQL_BREAKDOWN=#{grouped.transform_values(&:size).inspect}"
    assert_operator queries.size, :<=, 40, "35 project allocations must be summarized without N+1 SQL"
  end
end
