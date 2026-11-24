require "test_helper"
require "zip"
require "stringio"

class Abroa::XlsxRowsTest < ActiveSupport::TestCase
  test "reads shared and inline strings and preserves actual spreadsheet row positions" do
    rows = Abroa::XlsxRows.read(workbook)
    assert_equal [ "Date", "Amount", "Description" ], rows[0]
    assert_equal [], rows[1]
    assert_equal [ "2025-01-10", "-12.50", "Cafe" ], rows[2]
  end

  test "XLSX formulas are flagged rather than executed or accepted from cached values" do
    mapping = { date: "Date", amount: "Amount", description: "Description",
      date_format: "%Y-%m-%d", signage: "inflows_positive" }
    result = Abroa::StatementParser.parse_xlsx(bytes: workbook(formula: true), source_kind: "generic_xlsx",
      source_instance_key: "bank-1", mapping: mapping, default_currency: "GBP")
    assert_empty result.records
    assert_equal [ 3 ], result.issues.map(&:row_number)
  end

  test "XLSX external worksheet relationship is rejected" do
    assert_raises(Abroa::StatementParser::UnsupportedFormat) do
      Abroa::XlsxRows.read(workbook(external: true))
    end
  end

  private
    def workbook(formula: false, external: false)
      amount = formula ? "<c r='B3'><f>1+1</f><v>2</v></c>" : "<c r='B3'><v>-12.50</v></c>"
      relationship = external ? "Target='https://example.invalid/sheet.xml' TargetMode='External'" : "Target='worksheets/sheet1.xml'"
      Zip::OutputStream.write_buffer do |zip|
        files = {
          "xl/workbook.xml" => <<~XML,
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets><sheet name="Statement" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
          XML
          "xl/_rels/workbook.xml.rels" => <<~XML,
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" #{relationship}/>
            </Relationships>
          XML
          "xl/sharedStrings.xml" => "<sst xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><si><t>Date</t></si><si><t>Amount</t></si><si><t>Description</t></si></sst>",
          "xl/worksheets/sheet1.xml" => <<~XML
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
              <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>
              <row r="3"><c r="A3" t="inlineStr"><is><t>2025-01-10</t></is></c>#{amount}<c r="C3" t="inlineStr"><is><t>Cafe</t></is></c></row>
            </sheetData></worksheet>
          XML
        }
        files.each do |path, content|
          zip.put_next_entry(path)
          zip.write(content)
        end
      end.string.b
    end
end
