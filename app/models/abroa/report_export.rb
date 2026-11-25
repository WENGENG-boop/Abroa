require "csv"
require "stringio"

module Abroa
  # Immutable private report snapshot with authorization rechecked on every
  # download. Blobs are never exposed via signed/public ActiveStorage URLs.
  class ReportExport < ApplicationRecord
    self.table_name = "abroa_report_exports"
    Conflict = Class.new(StandardError)
    MAX_BYTES = 2.megabytes
    TTL = 7.days
    FILTERS = %w[scope project_id period_id start_on end_on month currency account_ids].freeze

    belongs_to :family
    belongs_to :owner, class_name: "User"
    belongs_to :project, class_name: "Abroa::StudyProject", optional: true
    has_one_attached :file

    validates :scope, inclusion: { in: %w[personal project parent] }
    validates :file_format, inclusion: { in: %w[csv json] }
    validates :status, inclusion: { in: %w[ready failed] }
    validate :same_family_unless_parent

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      where(family_id: user.family_id, owner_id: user.id)
    end

    def self.create_for!(actor, attributes:, format:, key:)
      raise ArgumentError, "Invalid export key" unless key.is_a?(String) &&
        key.bytesize.between?(1, 128)
      raise ArgumentError, "Unknown format" unless %w[json csv].include?(format)
      attrs = attributes.to_h.deep_stringify_keys
      raise ArgumentError, "Unexpected report export filter" if (attrs.keys - FILTERS).any?
      report_scope = attrs.fetch("scope")
      raise ArgumentError, "Invalid report export scope" unless %w[personal project parent].include?(report_scope)
      request_digest = Digest::SHA256.hexdigest(JSON.generate([ attrs.sort.to_h, format ]))
      key_digest = Digest::SHA256.hexdigest(key)

      StudyProject.with_actor(actor) do
        if (existing = for_user(actor).find_by(creation_key_digest: key_digest))
          raise Conflict, "Export request changed" unless existing.creation_request_digest == request_digest
          # A replay is an access request too; after Grant or account access
          # changes it must not expose even the archived export metadata.
          report_for!(actor, existing.filters)
          if existing.scope == "parent"
            raise ActiveRecord::RecordNotFound unless existing.grant_scope_digest ==
              grant_scope_digest(actor, existing.project_id)
          end
          next existing
        end

        data = report_for!(actor, attrs)
        raise ArgumentError, "Report is incomplete" if data[:incomplete]
        bytes = format == "json" ? JSON.pretty_generate(data) : csv_for(data)
        raise ArgumentError, "Report too large" unless bytes.bytesize.between?(1, MAX_BYTES)
        blob_type = format == "csv" ? "text/csv" : "application/json"
        resource = create!(family: actor.family, owner: actor,
          project_id: attrs["project_id"], scope: report_scope,
          file_format: format, status: "ready", filters: attrs,
          creation_key_digest: key_digest, creation_request_digest: request_digest,
          grant_scope_digest: report_scope == "parent" ? grant_scope_digest(actor, attrs["project_id"]) : nil,
          sha256: Digest::SHA256.hexdigest(bytes),
          byte_size: bytes.bytesize, expires_at: TTL.from_now)
        resource.file.attach(io: StringIO.new(bytes),
          filename: "abroa-report-#{resource.id}.#{format}",
          content_type: blob_type, identify: false)
        raise Conflict, "Report file unavailable" unless resource.file.attached?
        PlanningAuditEvent.record!(actor: actor, event_type: "report_export.created",
          resource: resource, safe_data: { format: format, scope: report_scope })
        resource
      end
    end

    def self.download_for!(viewer, id)
      raise ActiveRecord::RecordNotFound unless UuidFormat.valid?(id)
      record = for_user(viewer).where(status: "ready").find(id)
      raise ActiveRecord::RecordNotFound if record.expires_at <= Time.current
      if record.scope == "parent"
        raise ActiveRecord::RecordNotFound unless record.grant_scope_digest ==
          grant_scope_digest(viewer, record.project_id)
      end
      # Re-run all source permission checks without returning the fresh report.
      # An inaccessible account, revoked Grant or missing project blocks stale
      # private export even if its original blob is still stored.
      report_for!(viewer, record.filters)
      raise ActiveRecord::RecordNotFound unless record.file.attached? &&
        record.file.blob.byte_size == record.byte_size &&
        record.byte_size.between?(1, MAX_BYTES)
      bytes = record.file.download
      raise Conflict, "Export integrity changed" unless
        bytes.bytesize == record.byte_size && Digest::SHA256.hexdigest(bytes) == record.sha256

      PlanningAuditEvent.record!(actor: viewer, event_type: "report_export.downloaded",
        resource: record, safe_data: { format: record.file_format, scope: record.scope })
      { content: bytes, content_type: record.file_format == "csv" ? "text/csv" : "application/json",
        filename: "abroa-report-#{record.id}.#{record.file_format}" }
    end

    def self.report_for!(actor, values)
      attrs = values.to_h.deep_symbolize_keys
      scope = attrs.delete(:scope)
      case scope
      when "personal", "project"
        raise ArgumentError, "Parent period not accepted for a student export" if attrs.key?(:month)
        FinancialReport.for_student!(actor, scope: scope, **attrs)
      when "parent"
        raise ArgumentError, "Parent account/currency/date filter not allowed" if
          (attrs.keys - %i[project_id month period_id]).any?
        FinancialReport.for_parent!(actor, **attrs)
      else
        raise ArgumentError, "Invalid export scope"
      end
    end

    def self.grant_scope_digest(parent, project_id)
      raise ActiveRecord::RecordNotFound unless parent&.active?
      project = ParentOverview.authorized_project!(parent, project_id, "summary")
      relationships = Relationship.where(parent_user_id: parent.id,
        parent_family_id: parent.family_id, status: "active").select(:id)
      grants = Grant.where(project_id: project.id, relationship_id: relationships)
        .order(:id).pluck(:id, :capability, :resource_kind, :resource_id,
          :status, :expires_at, :updated_at)
      Digest::SHA256.hexdigest(JSON.generate(grants))
    end

    # CSV users commonly open files in Excel. Neutralize leading spreadsheet
    # formula operators, even when a value was supplied as imported free text.
    def self.csv_cell(value)
      string = value.nil? ? "" : value.to_s
      raise ArgumentError, "CSV value too long" if string.bytesize > 65_535
      if string.match?(/\A\s*[=+\-@]/) || string.match?(/\A[\t\r\n]/)
        "'#{string}"
      else
        string
      end
    end

    def self.csv_for(data)
      lines = []
      flatten = lambda do |object, prefix|
        case object
        when Hash
          object.each { |key, value| flatten.call(value, [ *prefix, key.to_s ]) }
        when Array
          object.each_with_index { |value, index| flatten.call(value, [ *prefix, index.to_s ]) }
        else
          lines << [ prefix.first.to_s, prefix.drop(1).join("."), object ]
        end
      end
      flatten.call(data, [])
      raise ArgumentError, "Report export too large" if lines.size > 12_000
      CSV.generate(force_quotes: true, row_sep: "\r\n") do |out|
        out << %w[section metric value]
        lines.each { |line| out << line.map { |value| csv_cell(value) } }
      end
    end

    def payload
      { id: id, scope: scope, format: file_format,
        status: status, byte_size: byte_size,
        expires_at: expires_at.utc.iso8601(6), created_at: created_at.utc.iso8601(6) }
    end

    private
      def same_family_unless_parent
        return unless owner && family_id
        errors.add(:family, :invalid) unless owner.family_id == family_id
        if project && scope != "parent" &&
            (project.family_id != family_id || project.owner_id != owner_id)
          errors.add(:project, :invalid)
        end
      end
  end
end
