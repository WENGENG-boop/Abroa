require "test_helper"

class Abroa::PdfSourceTest < ActiveSupport::TestCase
  test "normalized PDF extraction rows are evidence rather than ledger postings" do
    user = users(:family_admin)
    account = accounts(:depository)
    statement = mock
    statement.stubs(:family_id).returns(user.family_id)
    statement.stubs(:account_id).returns(account.id)
    statement.stubs(:content_sha256).returns("a" * 64)
    statement.stubs(:manageable_by?).with(user).returns(true)

    row = mock
    row.stubs(:source_row_number).returns(7)
    row.stubs(:date_iso).returns("2025-01-10")
    row.stubs(:amount).returns("12.50")
    row.stubs(:signed_amount).returns(BigDecimal("12.50"))
    row.stubs(:currency).returns("USD")
    row.stubs(:name).returns("Synthetic PDF purchase")
    row.stubs(:valid?).returns(true)
    rows = mock
    rows.stubs(:ordered).returns([ row ])

    import = mock
    import.stubs(:is_a?).with(PdfImport).returns(true)
    import.stubs(:family_id).returns(user.family_id)
    import.stubs(:account).returns(account)
    import.stubs(:account_statement).returns(statement)
    import.stubs(:importing?).returns(false)
    import.stubs(:reverting?).returns(false)
    import.stubs(:rows).returns(rows)
    AccountPolicy.any_instance.stubs(:permits?).with(:write).returns(true)

    assert_no_difference "Entry.count" do
      result = Abroa::PdfSource.preview(user: user, pdf_import: import, source_instance_key: "pdf-account")
      assert_empty result.issues
      assert_equal "generic_pdf", result.records.first.source_kind
      assert_equal "file:#{'a' * 64}:7", result.records.first.source_row_key
      assert_equal "outflow", result.records.first.direction
      assert_equal BigDecimal("12.50"), result.records.first.amount
    end
  end
end
