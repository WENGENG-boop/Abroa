module Abroa
  class StudyProject < ApplicationRecord
    self.table_name = "abroa_study_projects"
    Conflict = Class.new(StandardError)
    FIELDS = %i[name country origin_country city school timezone start_on end_on currency].freeze

    belongs_to :family
    belongs_to :owner, class_name: "User"
    has_many :periods, class_name: "Abroa::StudyPeriod", foreign_key: :project_id
    has_many :budget_nodes, class_name: "Abroa::BudgetNode", foreign_key: :project_id
    has_many :project_accounts, class_name: "Abroa::ProjectAccount", foreign_key: :project_id
    has_many :allocations, class_name: "Abroa::EntryAllocation", foreign_key: :project_id

    validates :name, :country, :timezone, :start_on, :currency, presence: true
    validates :status, inclusion: { in: %w[planning active completed archived] }
    validate :valid_scope
    validate :valid_dates
    before_validation { self.currency = Decimal.currency!(currency) if currency.present? }

    def self.with_actor(user)
      raise ActiveRecord::RecordNotFound unless user
      user.with_lock do
        raise ActiveRecord::RecordNotFound unless user.active? && !user.guest?
        user.family.with_lock { yield }
      end
    end

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active?
      where(family_id: user.family_id, owner_id: user.id)
    end

    def self.find_for!(user, id)
      for_user(user).find(id)
    end

    def self.create_for!(user, attributes:, key:)
      attributes = attributes.symbolize_keys
      raise ArgumentError, "Unknown project field" unless (attributes.keys - FIELDS).empty?
      raise ArgumentError, "Invalid idempotency key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      digest = Digest::SHA256.hexdigest(key)
      request = Digest::SHA256.hexdigest(attributes.sort.to_h.to_json)
      with_actor(user) do
        existing = for_user(user).find_by(creation_key_digest: digest)
        if existing
          raise Conflict, "Project request changed" unless existing.creation_request_digest == request
          next existing
        end
        record = create!(attributes.merge(owner: user, family: user.family, creation_key_digest: digest, creation_request_digest: request))
        PlanningAuditEvent.record!(actor: user, event_type: "study_project.created", resource: record)
        record
      end
    end

    def self.mutate_for!(user, id, version:, writable: true, event_type: "study_project.updated")
      with_actor(user) do
        project = find_for!(user, id)
        project.lock!
        raise Conflict, "Project version changed" unless version.is_a?(Integer) && project.lock_version == version
        project.ensure_writable! if writable
        yield project
        project.save!
        PlanningAuditEvent.record!(actor: user, event_type: event_type, resource: project)
        project
      end
    end

    def self.change_for!(user, id, version:, attributes:)
      attributes = attributes.symbolize_keys
      raise ArgumentError, "Unknown project field" unless (attributes.keys - FIELDS - [ :status ]).empty?
      raise ArgumentError, "Invalid lifecycle state" if attributes.key?(:status) && !%w[planning active completed].include?(attributes[:status])
      mutate_for!(user, id, version: version) { |project| project.assign_attributes(attributes) }
    end

    def self.archive_for!(user, id, version:)
      mutate_for!(user, id, version: version, event_type: "study_project.archived") do |project|
        project.assign_attributes(previous_status: project.status, status: "archived", archived_at: Time.current)
      end
    end

    def self.restore_for!(user, id, version:)
      mutate_for!(user, id, version: version, writable: false, event_type: "study_project.restored") do |project|
        raise Conflict, "Project is not archived" unless project.status == "archived"
        project.assign_attributes(status: project.previous_status, previous_status: nil, archived_at: nil)
      end
    end

    def ensure_writable!
      raise Conflict, "Project is archived" if status == "archived"
    end

    def payload
      attributes.slice("id", *FIELDS.map(&:to_s), "status", "archived_at", "lock_version")
    end

    private
      def valid_scope
        errors.add(:owner, :invalid) unless owner && owner.family_id == family_id
        %i[country origin_country].each do |field|
          code = public_send(field)
          errors.add(field, :invalid) if code.present? && (code.length != 2 || ISO3166::Country.new(code).nil?)
        end
        errors.add(:timezone, :invalid) unless ActiveSupport::TimeZone[timezone].present?
      end

      def valid_dates
        return unless start_on
        errors.add(:end_on, :invalid) if end_on && end_on < start_on
        if persisted? && periods.where("start_on < ?", start_on).exists?
          errors.add(:start_on, "excludes existing periods")
        end
        if persisted? && end_on && periods.where("end_on > ?", end_on).exists?
          errors.add(:end_on, "excludes existing periods")
        end
      end
  end
end
