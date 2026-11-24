module Abroa
  class PdfSource
    # Reuses existing PDF extraction rows, not the legacy import posting operation.
    # A preview is evidence only and may be a subset of the original statement.
    def self.preview(user:, pdf_import:, source_instance_key:)
      unless user && pdf_import.is_a?(PdfImport) && pdf_import.family_id == user.family_id
        raise ArgumentError, "PDF source unavailable"
      end
      account = pdf_import.account
      statement = pdf_import.account_statement
      unless account && account.family_id == user.family_id && statement &&
          statement.family_id == user.family_id && statement.account_id == account.id &&
          statement.manageable_by?(user) && AccountPolicy.new(user, account).permits?(:write) &&
          !pdf_import.importing? && !pdf_import.reverting?
        raise ArgumentError, "PDF source unavailable"
      end

      sha = statement.content_sha256
      NormalizedSource.file_row_key(sha, 1)
      rows = pdf_import.rows.ordered
      raise StatementParser::UnsupportedFormat, "Too many extracted PDF rows" if rows.size > StatementParser::MAX_ROWS
      records, issues = [], []
      rows.each do |row|
        number = row.source_row_number
        begin
          raise ArgumentError, "Invalid extracted row" unless row.valid?
          Decimal.money!(row.amount)
          amount = Decimal.money!(row.signed_amount)
          date = Date.iso8601(row.date_iso)
          description = row.name.to_s.strip.presence || "Imported PDF transaction"
          raise ArgumentError, "Formula-like description" if StatementParser::FORMULA.match?(description)
          digest = Digest::SHA256.hexdigest(JSON.generate([ number, date.iso8601, amount.to_s("F"), row.currency, description ]))
          records << NormalizedSource.build(
            source_kind: "generic_pdf", source_instance_key: source_instance_key,
            source_row_key: NormalizedSource.file_row_key(sha, number), raw_digest: digest,
            local_date: date, amount: amount.abs, currency: row.currency,
            direction: amount.negative? ? "inflow" : "outflow", provider_status: "posted",
            transaction_kind: "unknown", description: description.truncate(256)
          )
        rescue ArgumentError, Date::Error
          issues << StatementParser::Issue.new(row_number: number, code: "invalid_row", message: "Invalid extracted PDF field")
        end
      end
      StatementParser::Result.new(file_sha256: sha, records: records.freeze, issues: issues.freeze)
    end
  end
end
