module Abroa
  class StatementIntake < ApplicationRecord
    self.table_name = "abroa_statement_intakes"
    Conflict = Class.new(StandardError)
    FILE_KINDS = %w[bank_statement alipay_statement wechat_statement generic_csv generic_xlsx generic_pdf].freeze
    PREVIEW_ROWS = 100

    belongs_to :family
    belongs_to :statement, class_name: "AccountStatement"
    belongs_to :account, optional: true
    belongs_to :actor, class_name: "User", optional: true
    belongs_to :pdf_import, class_name: "PdfImport", optional: true

    validates :source_kind, inclusion: { in: FILE_KINDS }
    validates :config_digest, :preview_digest, :file_digest, presence: true
    validate :initial_provenance, on: :create

    # Upload remains in the existing Statement Vault. Preview is a read-only
    # operation; publishing stages evidence and review work, not ledger writes.
    def self.preview_for!(user, statement_id:, source_kind:, mapping: nil, separator: ",", pdf_import_id: nil)
      with_statement(user, statement_id) do |family, statement, account|
        config, pdf_import = config_for!(family, statement, account, source_kind, mapping, separator, pdf_import_id)
        config_digest = digest(config)
        receipt = find_by(statement: statement)
        if receipt && (receipt.account_id != account.id || receipt.config_digest != config_digest)
          raise Conflict, "Statement already staged with another configuration"
        end
        result = parse!(user, statement, config, pdf_import)
        preview_digest = preview_hash(config_digest, result)
        {
          statement_id: statement.id, account_id: account.id, source_kind: source_kind,
          file_sha256: result.file_sha256, preview_digest: preview_digest,
          record_count: result.records.size, issue_count: result.issues.size,
          rows: result.records.first(PREVIEW_ROWS).map { |record| record.payload.merge("source_row_key" => record.source_row_key) },
          issues: result.issues.first(PREVIEW_ROWS).map(&:to_h)
        }
      end
    end

    def self.publish_for!(user, statement_id:, source_kind:, preview_digest:, mapping: nil, separator: ",", pdf_import_id: nil, accept_invalid_rows: false)
      unless preview_digest.is_a?(String) && preview_digest.match?(/\A[0-9a-f]{64}\z/) &&
          [ true, false ].include?(accept_invalid_rows)
        raise ArgumentError, "Expected a valid preview digest and boolean error confirmation"
      end
      with_statement(user, statement_id) do |family, statement, account|
        config, pdf_import = config_for!(family, statement, account, source_kind, mapping, separator, pdf_import_id)
        config_digest = digest(config)
        existing = find_by(statement: statement)
        if existing
          unless existing.account_id == account.id && existing.config_digest == config_digest &&
              existing.preview_digest == preview_digest &&
              existing.summary["accepted_invalid_rows"] == accept_invalid_rows
            raise Conflict, "Statement already staged with a different request"
          end
          next existing
        end

        result = parse!(user, statement, config, pdf_import)
        unless preview_hash(config_digest, result) == preview_digest
          raise Conflict, "Preview is stale; obtain a fresh preview"
        end
        raise ArgumentError, "No valid statement rows" if result.records.empty?
        if result.issues.any? && !accept_invalid_rows
          raise ArgumentError, "Invalid rows require explicit confirmation"
        end

        counts = { "record_count" => result.records.size, "issue_count" => result.issues.size,
          "review_count" => 0, "ignored_count" => 0, "existing_count" => 0,
          "accepted_invalid_rows" => accept_invalid_rows }
        seen = Set.new
        result.records.each do |record|
          canonical = SourceRecord.ingest!(family: family, record: record, account: account,
            statement: statement, import: pdf_import)
          # A reused personal order assigned to another account must not leak
          # that account's id or silently move its provenance.
          raise Conflict, "Source identity belongs to another account" unless canonical.account_id == account.id
          if !seen.add?(canonical.id)
            counts["existing_count"] += 1
          elsif canonical.status == "ignored"
            counts["ignored_count"] += 1
          elsif canonical.status.in?(%w[parsed review]) && canonical.entry_id.nil?
            SourceReview.open_for!(user, canonical.id)
            counts["review_count"] += 1
          else
            counts["existing_count"] += 1
          end
        end
        create!(family: family, actor: user, account: account, statement: statement, pdf_import: pdf_import,
          source_kind: source_kind, config_digest: config_digest, preview_digest: preview_digest,
          file_digest: result.file_sha256, summary: counts)
      end
    end

    def self.visible_for!(user, statement_id)
      statement = user.family.account_statements.find(statement_id)
      raise ActiveRecord::RecordNotFound unless statement.account_id && statement.viewable_by?(user)
      receipt = where(family: user.family, statement: statement).find_by!
      raise ActiveRecord::RecordNotFound unless receipt.account_id == statement.account_id
      receipt
    end

    def payload
      { id: id, statement_id: statement_id, account_id: account_id, source_kind: source_kind,
        file_sha256: file_digest, preview_digest: preview_digest, status: "staged", summary: summary }
    end

    class << self
      private
        def with_statement(user, statement_id)
          raise ActiveRecord::RecordNotFound unless user
          user.with_lock do
            raise ActiveRecord::RecordNotFound unless user.active? && !user.guest?
            family = user.family
            family.with_lock do
              statement = family.account_statements.find(statement_id)
              raise ActiveRecord::RecordNotFound unless statement.account_id
              account = family.accounts.writable_by(user).find(statement.account_id)
              account.lock!
              statement.lock!
              unless statement.account_id == account.id && statement.manageable_by?(user) &&
                  AccountPolicy.new(user, account).permits?(:write)
                raise ActiveRecord::RecordNotFound
              end
              yield family, statement, account
            end
          end
        end

        def config_for!(family, statement, account, kind, mapping, separator, pdf_import_id)
          raise ArgumentError, "Unsupported statement kind" unless FILE_KINDS.include?(kind)
          extension = File.extname(statement.filename).downcase
          valid = case extension
          when ".csv" then (StatementParser::PERSONAL_KINDS + %w[bank_statement generic_csv]).include?(kind)
          when ".xlsx" then (StatementParser::PERSONAL_KINDS + %w[bank_statement generic_xlsx]).include?(kind)
          when ".pdf" then kind == "generic_pdf"
          end
          raise ArgumentError, "Statement type and file extension differ" unless valid
          if mapping && (!mapping.is_a?(Hash) || !mapping.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } ||
              !mapping.values.all? { |value| value.is_a?(String) && value.bytesize <= 512 } || mapping.size > 16)
            raise ArgumentError, "Invalid column mapping"
          end
          unless [ ",", ";", "\t" ].include?(separator)
            raise ArgumentError, "Unsupported CSV separator"
          end
          pdf_import = nil
          if kind == "generic_pdf"
            raise ArgumentError, "PDF extraction id is required" unless pdf_import_id.present? && mapping.nil?
            pdf_import = PdfImport.where(family: family, account_statement: statement, account: account).find(pdf_import_id)
            pdf_import.lock!
            if pdf_import.data_committed? || pdf_import.importing? || pdf_import.reverting?
              raise Conflict, "PDF extraction is busy or already committed"
            end
          elsif pdf_import_id.present?
            raise ArgumentError, "PDF extraction is only valid for PDF statements"
          end
          source_instance = if StatementParser::PERSONAL_KINDS.include?(kind)
            "personal:#{account.owner_id}:#{kind}"
          else
            "account:#{account.id}"
          end
          config = { "statement_id" => statement.id, "account_id" => account.id,
            "source_kind" => kind, "extension" => extension, "mapping" => mapping&.stringify_keys&.sort&.to_h,
            "separator" => separator, "pdf_import_id" => pdf_import&.id, "currency" => account.currency,
            "source_instance_key" => source_instance }
          [ config, pdf_import ]
        end

        def parse!(user, statement, config, pdf_import)
          if config["source_kind"] == "generic_pdf"
            return PdfSource.preview(user: user, pdf_import: pdf_import, source_instance_key: config["source_instance_key"])
          end
          limit = config["extension"] == ".csv" ? StatementParser::MAX_BYTES : XlsxRows::MAX_BYTES
          unless statement.original_file.attached? && statement.byte_size.between?(1, limit) &&
              statement.original_file.blob.byte_size.between?(1, limit)
            raise StatementParser::UnsupportedFormat, "Invalid stored statement size"
          end
          bytes = String.new(encoding: Encoding::BINARY)
          statement.original_file.download do |chunk|
            raise StatementParser::UnsupportedFormat, "Statement exceeds size limit" if bytes.bytesize + chunk.bytesize > limit
            bytes << chunk.b
          end
          unless Digest::SHA256.hexdigest(bytes) == statement.content_sha256
            raise Conflict, "Stored statement digest changed"
          end
          arguments = { bytes: bytes, source_kind: config["source_kind"],
            source_instance_key: config["source_instance_key"], mapping: config["mapping"],
            default_currency: config["currency"] }
          if config["extension"] == ".csv"
            StatementParser.parse_csv(**arguments, separator: config["separator"])
          else
            StatementParser.parse_xlsx(**arguments)
          end
        end

        def preview_hash(config_digest, result)
          digest([ config_digest, result.file_sha256,
            result.records.map { |row| [ row.source_row_key, row.external_id, row.raw_digest, row.payload ] },
            result.issues.map(&:to_h) ])
        end

        def digest(value)
          Digest::SHA256.hexdigest(JSON.generate(value))
        end
    end

    private
      def initial_provenance
        unless account && account.family_id == family_id && statement &&
            statement.family_id == family_id && statement.account_id == account_id &&
            actor&.family_id == family_id && statement.content_sha256 == file_digest
          errors.add(:base, "Invalid statement provenance")
        end
      end
  end
end
