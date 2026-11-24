require "zip"
require "stringio"
require "nokogiri"
require "bigdecimal"

module Abroa
  class XlsxRows
    MAX_BYTES = 25 * 1024 * 1024
    MAX_XML = 16 * 1024 * 1024
    MAX_TOTAL = 64 * 1024 * 1024
    MAX_ENTRIES = 256
    NS = { "s" => "http://schemas.openxmlformats.org/spreadsheetml/2006/main" }.freeze
    REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    PACKAGE_NS = { "p" => "http://schemas.openxmlformats.org/package/2006/relationships" }.freeze
    UNSUPPORTED_CELL = :unsupported_cell
    DATE_STYLES = [ 14, 15, 16, 17, 22, 27, 28, 29, 30, 31, 34, 35, 36, 50, 51, 52, 53, 54, 55, 56, 57, 58 ].freeze

    def self.read(bytes)
      unless bytes.is_a?(String) && bytes.bytesize.between?(1, MAX_BYTES)
        raise StatementParser::UnsupportedFormat, "Unsupported XLSX size"
      end
      Zip::File.open_buffer(StringIO.new(bytes.b)) do |zip|
        new(zip).rows
      end
    rescue Zip::Error, Nokogiri::XML::SyntaxError, EncodingError, ArgumentError, EOFError
      raise StatementParser::UnsupportedFormat, "Invalid or unsupported XLSX"
    end

    def initialize(zip)
      @zip = zip
      entries = zip.entries
      unless entries.size <= MAX_ENTRIES && entries.sum(&:size) <= MAX_TOTAL &&
          entries.map(&:name).uniq.size == entries.size &&
          entries.all? { |entry| entry.size.between?(0, MAX_XML) && safe_path?(entry.name) }
        unsupported!("Unsafe XLSX archive")
      end
    end

    def rows
      workbook = xml("xl/workbook.xml")
      sheets = workbook.xpath("/s:workbook/s:sheets/s:sheet", NS)
      # Keep file/row identity unambiguous. Multi-sheet support requires sheet-aware identities.
      unsupported!("Exactly one worksheet is required") unless sheets.size == 1
      sheet = sheets.first
      unsupported!("Hidden worksheet") unless [ nil, "visible" ].include?(sheet["state"])
      id = sheet.attribute_with_ns("id", REL_NS)&.value
      rels = xml("xl/_rels/workbook.xml.rels")
      matches = rels.xpath("/p:Relationships/p:Relationship", PACKAGE_NS).select { |rel| rel["Id"] == id }
      unsupported!("Invalid worksheet relationship") unless id.present? && matches.one?
      rel = matches.first
      target = rel["Target"].to_s
      target = target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}"
      unless rel["TargetMode"].nil? || rel["TargetMode"] == "Internal"
        unsupported!("External worksheet relationship")
      end
      unless rel["Type"] == "#{REL_NS}/worksheet" && target.match?(%r{\Axl/worksheets/[A-Za-z0-9_.-]+\.xml\z}) && safe_path?(target)
        unsupported!("Unsupported worksheet relationship")
      end

      @shared = shared_strings
      @date_styles = date_styles
      @date_1904 = %w[1 true].include?(workbook.at_xpath("/s:workbook/s:workbookPr", NS)&.[]("date1904"))
      result = []
      xml(target).xpath("/s:worksheet/s:sheetData/s:row", NS).each do |row|
        number = integer!(row["r"], StatementParser::MAX_ROWS + 100)
        unsupported!("Rows must be ordered and unique") unless number > result.length
        result << [] while result.length < number - 1
        cells = []
        occupied = {}
        row.xpath("s:c", NS).each do |cell|
          match = cell["r"].to_s.match(/\A([A-Z]{1,3})([1-9]\d*)\z/)
          unsupported!("Invalid cell reference") unless match && match[2] == number.to_s
          column = match[1].each_byte.reduce(0) { |n, char| n * 26 + char - 64 }
          unsupported!("Invalid column") unless column.between?(1, StatementParser::MAX_COLUMNS) && !occupied[column]
          occupied[column] = true
          cells[column - 1] = value(cell)
        end
        result << cells
      end
      result
    end

    private
      def safe_path?(name)
        !name.start_with?("/") && !name.include?("\\") && !name.include?("\0") &&
          !name.include?(":") && !name.split("/").any? { |part| part == ".." || part == "." }
      end

      def unsupported!(message)
        raise StatementParser::UnsupportedFormat, message
      end

      def xml(path, optional: false)
        entry = @zip.find_entry(path)
        return nil if optional && entry.nil?
        unsupported!("Missing workbook component") if entry.nil? || entry.directory?
        content = entry.get_input_stream { |stream| stream.read(MAX_XML + 1) }
        unsupported!("Workbook component exceeds limit") if content.nil? || content.bytesize > MAX_XML
        doc = Nokogiri::XML(content) { |config| config.strict.nonet }
        unsupported!("XML document types are forbidden") if doc.internal_subset
        doc
      end

      def shared_strings
        doc = xml("xl/sharedStrings.xml", optional: true)
        return [] unless doc
        doc.xpath("/s:sst/s:si", NS).map { |item| text(item) }
      end

      def text(node)
        node.xpath("s:t | s:r/s:t", NS).map(&:text).join
      end

      def date_styles
        doc = xml("xl/styles.xml", optional: true)
        return [] unless doc
        # Only known built-in date formats; unknown custom formats are not guessed.
        doc.xpath("/s:styleSheet/s:cellXfs/s:xf", NS).map do |style|
          DATE_STYLES.include?(style["numFmtId"].to_i)
        end
      end

      def integer!(raw, max, min: 1)
        unless raw.is_a?(String) && raw.match?(/\A\d{1,8}\z/) && raw.to_i.between?(min, max)
          unsupported!("Invalid worksheet index")
        end
        raw.to_i
      end

      def value(cell)
        return UNSUPPORTED_CELL if cell.at_xpath("s:f", NS)
        raw = cell.at_xpath("s:v", NS)&.text
        case cell["t"]
        when "s"
          return UNSUPPORTED_CELL unless raw&.match?(/\A\d{1,8}\z/) && raw.to_i < @shared.length
          @shared.fetch(raw.to_i)
        when "inlineStr"
          node = cell.at_xpath("s:is", NS)
          node ? text(node) : ""
        when "str", "d"
          raw
        when nil, "n"
          if raw && @date_styles[cell["s"].to_i]
            excel_date(raw)
          else
            raw
          end
        else
          UNSUPPORTED_CELL
        end
      end

      def excel_date(raw)
        return UNSUPPORTED_CELL unless raw.match?(/\A\d{1,7}(?:\.\d{1,16})?\z/)
        value = BigDecimal(raw)
        days = value.floor
        return UNSUPPORTED_CELL if !@date_1904 && days == 60
        base = @date_1904 ? Date.new(1904, 1, 1) : Date.new(1899, 12, 31)
        date = base + days - (!@date_1904 && days > 60 ? 1 : 0)
        return UNSUPPORTED_CELL unless date.year.between?(1900, 9999)
        return date.iso8601 if value == days
        seconds = ((value - days) * 86_400).floor
        "#{date.iso8601} %02d:%02d:%02d" % [ seconds / 3600, seconds / 60 % 60, seconds % 60 ]
      end
  end
end
