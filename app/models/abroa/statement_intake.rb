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
    # operation; publishing stages evidence and reviews, and can attach
    # uniquely matched evidence to an existing movement without adding entries.
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
          raise Conflict, "Statement has been rolled back" if existing.summary["reversed_at"].present?
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
          "auto_linked_count" => 0, "accepted_invalid_rows" => accept_invalid_rows }
        seen = {}
        preexisting = SourceRecord.where(family: family, statement: statement).pluck(:id).to_set
        result.records.each do |record|
          funding_account = confirmed_account_for!(user, family, account, record)
          canonical = SourceRecord.ingest!(family: family, record: record, account: funding_account,
            statement: statement, import: pdf_import)
          # A reused personal order assigned to another account must not leak
          # that account's id or silently move its provenance.
          raise Conflict, "Source identity belongs to another account" unless canonical.account_id == funding_account.id
          counts["existing_count"] += 1 if seen.key?(canonical.id)
          seen[canonical.id] = canonical
        end

        # Stage all evidence before making decisions so competing orders in the
        # same file cannot cause the first row to be linked arbitrarily.
        seen.each_value do |canonical|
          canonical.reload
          if canonical.status == "ignored"
            counts["ignored_count"] += 1
          elsif canonical.status.in?(%w[parsed review]) && canonical.entry_id.nil?
            review = SourceReview.open_for!(user, canonical.id)
            action = SourceReview.try_auto_link_for!(user, review_id: review.id)
            counts[action ? "auto_linked_count" : "review_count"] += 1
          else
            counts["existing_count"] += 1
          end
        end
        # Keep the ownership manifest private; a receipt may contain observations
        # of sources that existed before this particular statement was published.
        counts["source_ids"] = seen.keys.sort
        counts["owned_source_ids"] = seen.values.select { |source| source.statement_id == statement.id &&
          !preexisting.include?(source.id) }.map(&:id).sort
        create!(family: family, actor: user, account: account, statement: statement, pdf_import: pdf_import,
          source_kind: source_kind, config_digest: config_digest, preview_digest: preview_digest,
          file_digest: result.file_sha256, summary: counts)
      end
    end

    # A batch rollback is atomic. Reuse the existing per-action dependency
    # checks; never erase evidence or an unrelated ledger movement.
    def self.rollback_for!(user, statement_id:)
      with_statement(user, statement_id) do |family, statement, account|
        receipt = find_by!(family: family, statement: statement)
        receipt.lock!
        raise ActiveRecord::RecordNotFound unless receipt.account_id == account.id && receipt.actor_id == user.id
        next receipt if receipt.summary["reversed_at"].present?

        ids = receipt.summary["source_ids"]
        owned = receipt.summary["owned_source_ids"]
        unless ids.is_a?(Array) && ids.any? && ids == owned
          raise Conflict, "Batch contains shared or untracked provenance; review its actions individually"
        end
        sources = SourceRecord.where(family: family, statement: statement, id: ids).order(:id).lock.to_a
        raise Conflict, "Batch source ownership changed" unless sources.size == ids.size
        target_ids = sources.map(&:account_id).uniq
        targets = family.accounts.writable_by(user).where(id: target_ids).order(:id).lock.to_a
        unless targets.size == target_ids.size && targets.all? { |target| target.owner_id == account.owner_id &&
            AccountPolicy.new(user, target).permits?(:write) }
          raise ActiveRecord::RecordNotFound
        end
        sources.each do |source|
          if source.observations.where.not(statement_id: statement.id).exists? ||
              source.observations.where(statement_id: nil).exists? ||
              where(family: family).where.not(id: receipt.id).where("summary -> 'source_ids' @> ?::jsonb", [source.id].to_json).exists? ||
              source.observations.where(status: "conflict").exists?
            raise Conflict, "Source has later or shared evidence"
          end
          actions = SourceAction.where(family: family, source_record: source, reversed_at: nil).order(:id).lock.to_a
          raise Conflict, "Source has multiple resolution actions" if actions.size > 1
          if actions.one?
            SourceReview.reverse_for!(user, action_id: actions.first.id)
          elsif source.entry_id.present? || !source.status.in?(%w[parsed review ignored reversed])
            raise Conflict, "Source has an untracked ledger dependency"
          elsif source.status != "reversed"
            source.update!(status: "reversed")
          end
          SourceReview.where(family: family, source_record: source, status: "pending").find_each do |review|
            review.update!(status: "dismissed", resolved_by: user, resolved_at: Time.current,
              evidence: review.evidence.merge("batch_rollback_id" => receipt.id))
          end
        end
        receipt.update!(summary: receipt.summary.merge("reversed_at" => Time.current.iso8601(6),
          "reversed_by_id" => user.id, "reversed_source_count" => sources.size))
        receipt
      end
    end

    def self.visible_for!(user, statement_id)
      statement = user.family.account_statements.find(statement_id)
      raise ActiveRecord::RecordNotFound unless statement.account_id && statement.viewable_by?(user)
      receipt = find_by!(family: user.family, statement: statement)
      raise ActiveRecord::RecordNotFound unless receipt.account_id == statement.account_id
      receipt
    end

    def payload
      { id: id, statement_id: statement_id, account_id: account_id, source_kind: source_kind,
        file_sha256: file_digest, preview_digest: preview_digest,
        status: summary["reversed_at"].present? ? "reversed" : "staged",
        summary: summary.except("source_ids", "owned_source_ids", "reversed_by_id") }
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

        # A later statement may repeat an order already attributed by the
        # user. Respect its confirmed account, never silently reassign it.
        def confirmed_account_for!(user, family, account, record)
          return account unless StatementParser::PERSONAL_KINDS.include?(record.source_kind) && record.external_id
          existing = SourceRecord.find_by(family: family, source_kind: record.source_kind,
            source_instance_key: record.source_instance_key, external_id: record.external_id)
          return account unless existing && existing.account_id != account.id
          confirmed = SourceReview.where(family: family, source_record: existing)
            .where("evidence -> 'funding_assignment' ->> 'to_account_id' = ?", existing.account_id).exists?
          raise Conflict, "Source identity belongs to another account" unless confirmed
          target = family.accounts.writable_by(user).find(existing.account_id)
          target.lock!
          unless target.owner_id == account.owner_id && AccountPolicy.new(user, target).permits?(:write) &&
              existing.statement&.manageable_by?(user)
            raise ActiveRecord::RecordNotFound
          end
          target
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
