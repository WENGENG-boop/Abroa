require "test_helper"

class Abroa::ReportExportTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @outsider = users(:empty)
    @bank = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Student personal bank",
      currency: "GBP", balance: 500)
    @bank.entries.create!(entryable: Transaction.new, name: "Paper and textbooks",
      amount: 80, currency: "GBP", date: Date.new(2025, 2, 12))
  end

  test "CSV formula injection is neutralized in every exported string cell" do
    payload = { "project" => { "name" => "=HYPERLINK(\"https://evil.test\")",
      "danger" => "+SUM(A1)", "new_lines" => "@attack", "tab" => "\t=1" } }
    csv = Abroa::ReportExport.csv_for(payload)
    rows = CSV.parse(csv)
    data = rows.map { |row| row[2] }.compact
    assert data.any? { |value| value.start_with?("'=HYPERLINK") }
    assert data.any? { |value| value.start_with?("'+SUM") }
    assert data.any? { |value| value.start_with?("'@attack") }
    assert data.any? { |value| value.start_with?("'\t=1") }
    assert_not_includes csv, "\r\n=1"
  end

  test "creates an encrypted-private-store-bound export, with audit and identical key replay" do
    before_entries = Entry.count
    options = { scope: "personal", start_on: "2025-02-01", end_on: "2025-02-28",
      currency: "GBP", account_ids: [ @bank.id ] }
    export = Abroa::ReportExport.create_for!(@student, attributes: options,
      format: "csv", key: "export-idempotent")
    assert export.file.attached?
    assert_equal "ready", export.status
    assert_equal "text/csv", export.file.blob.content_type
    assert_equal Digest::SHA256.hexdigest(export.file.download), export.sha256
    same = Abroa::ReportExport.create_for!(@student, attributes: options,
      format: "csv", key: "export-idempotent")
    assert_equal export.id, same.id
    assert_equal before_entries, Entry.count
    assert Abroa::PlanningAuditEvent.where(
      event_type: "report_export.created", resource_id: export.id).exists?
    assert_raises(Abroa::ReportExport::Conflict) do
      Abroa::ReportExport.create_for!(@student,
        attributes: options.merge(currency: "EUR"), format: "csv", key: "export-idempotent")
    end
  end

  test "download refuses outsider, logs owner access, and refuses expired artifact" do
    exp = Abroa::ReportExport.create_for!(@student,
      attributes: { scope: "personal", start_on: "2025-02-01",
        end_on: "2025-02-28", currency: "GBP", account_ids: [ @bank.id ] },
      format: "json", key: "report-download")
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ReportExport.download_for!(@outsider, exp.id)
    end
    payload = Abroa::ReportExport.download_for!(@student, exp.id)
    assert payload[:content].include?("cash_flow")
    assert_equal "application/json", payload[:content_type]
    assert Abroa::PlanningAuditEvent.where(
      event_type: "report_export.downloaded", resource_id: exp.id).exists?
    exp.reload.update!(expires_at: 1.minute.ago)
    assert_operator exp.reload.expires_at, :<, Time.current,
      "Fixture must persist a timestamp before current time"
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ReportExport.download_for!(@student, exp.id)
    end
  end

  test "parent export cannot be read after report Grant revocation" do
    parent = @outsider
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: parent, student_enabled: false, parent_enabled: true)
    project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "Export privacy project", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "report-export-parent-project")
    Abroa::ProjectAccount.attach_for!(@student, project.id, @bank.id)
    _invite, token = Abroa::RelationshipInvite.issue_for!(parent,
      recipient_email: @student.email, recipient_role: "student", key: "report-export-parent-invite")
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    grant = Abroa::Grant.create_for!(@student, relation.id, project_id: project.id,
      capability: "summary", key: "report-export-parent-grant")
    exp = Abroa::ReportExport.create_for!(parent,
      attributes: { scope: "parent", project_id: project.id, month: "2025-02" },
      format: "csv", key: "parent-csv")
    assert Abroa::ReportExport.download_for!(parent, exp.id)[:content].include?("privacy_suppressed")
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ReportExport.download_for!(@student, exp.id)
    end
    Abroa::Grant.revoke_for!(@student, relation.id, grant.id, version: grant.lock_version)
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ReportExport.download_for!(parent, exp.id)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ReportExport.create_for!(parent,
        attributes: { scope: "parent", project_id: project.id, month: "2025-02" },
        format: "csv", key: "parent-csv")
    end
  end
end
