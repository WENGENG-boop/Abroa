module Abroa
  # A claim or obligation backed by a genuine Sure asset/liability valuation.
  # Linked bank transactions are never fabricated or changed by this model.
  class PersonalDebt < ApplicationRecord
    self.table_name = "abroa_personal_debts"
    Conflict = Class.new(StandardError)
    KINDS = %w[paid_for_other paid_by_other lent borrowed].freeze
    FIELDS = %i[kind contact_nickname purpose project_id source_entry_id currency
      personal_amount other_amount incurred_on due_on].freeze

    belongs_to :family
    belongs_to :owner, class_name: "User"
    belongs_to :project, class_name: "Abroa::StudyProject", optional: true
    belongs_to :debt_account, class_name: "Account"
    belongs_to :source_entry, class_name: "Entry", optional: true
    has_many :settlements, class_name: "Abroa::DebtSettlement", dependent: :restrict_with_exception

    validates :kind, inclusion: { in: KINDS }
    validates :direction, inclusion: { in: %w[receivable payable] }
    validates :status, inclusion: { in: %w[open partially_settled settled cancelled] }
    validates :contact_nickname, :currency, :incurred_on, presence: true
    validate :valid_scope

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active?
      where(family_id: user.family_id, owner_id: user.id)
    end

    def self.create_for!(user, attributes:, key:)
      raise ArgumentError, "Invalid idempotency key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      attrs = attributes.symbolize_keys
      raise ArgumentError, "Unknown debt field" if (attrs.keys - FIELDS).any?
      raise ArgumentError, "Unknown debt type" unless KINDS.include?(attrs[:kind])
      kind = attrs.fetch(:kind)
      nickname = attrs[:contact_nickname]
      raise ArgumentError, "Invalid contact" unless nickname.is_a?(String) && nickname.strip.present? &&
        nickname.bytesize <= 120
      currency = Decimal.currency!(attrs.fetch(:currency))
      personal = Decimal.money!(attrs.fetch(:personal_amount, "0"), nonnegative: true)
      other = Decimal.money!(attrs.fetch(:other_amount, "0"), nonnegative: true)
      amount = personal + other
      raise ArgumentError, "Amount must be positive" unless amount.positive?
      incurred = parse_date!(attrs.fetch(:incurred_on))
      due = attrs[:due_on].present? ? parse_date!(attrs[:due_on]) : nil
      raise ArgumentError, "Invalid due date" if due && due < incurred
      direction = %w[paid_for_other lent].include?(kind) ? "receivable" : "payable"
      principal = case kind
      when "paid_for_other", "lent", "borrowed" then other
      when "paid_by_other" then personal
      end
      raise ArgumentError, "Debt principal cannot be zero" unless principal.positive?
      raise ArgumentError, "Loan must not include personal spending" if %w[lent borrowed].include?(kind) && !personal.zero?
      raise ArgumentError, "Externally paid expense cannot have other share" if kind == "paid_by_other" && !other.zero?

      fields = { kind: kind, contact_nickname: nickname.strip, purpose: attrs[:purpose],
        currency: currency, personal_amount: personal, other_amount: other,
        incurred_on: incurred, due_on: due, direction: direction, principal_amount: principal }
      digest = Digest::SHA256.hexdigest(key)
      request_digest = Digest::SHA256.hexdigest(JSON.generate(attrs.stringify_keys.sort.to_h))
      StudyProject.with_actor(user) do
        existing = for_user(user).find_by(creation_key_digest: digest)
        if existing
          raise Conflict, "Request changed" unless existing.creation_request_digest == request_digest
          next existing
        end
        project = attrs[:project_id].present? ? StudyProject.find_for!(user, attrs[:project_id]) : nil
        project&.ensure_writable!
        entry = attrs[:source_entry_id].present? ? EntryAllocation.locked_entry!(user, attrs[:source_entry_id]) : nil
        validate_source!(kind, entry, amount: amount, incurred: incurred, currency: currency)
        debt_account = Account.create!(family: user.family, owner: user,
          accountable: (direction == "receivable" ? OtherAsset.new : OtherLiability.new),
          name: "Personal #{direction}: #{nickname.strip}", currency: currency, balance: 0)
        record = create!(fields.merge(family: user.family, owner: user, project: project,
          debt_account: debt_account, source_entry: entry,
          source_amount: entry&.amount, source_currency: entry&.currency, source_date: entry&.date,
          creation_key_digest: digest, creation_request_digest: request_digest))
        record.refresh_valuation!
        PlanningAuditEvent.record!(actor: user, event_type: "personal_debt.created",
          resource: record, safe_data: { direction: direction, kind: kind, currency: currency,
            principal: principal.to_s("F") })
        record
      end
    end

    def self.parse_date!(value)
      date = value.is_a?(Date) ? value : Date.iso8601(value.to_s)
      raise ArgumentError, "Invalid date" if date.year <= 0 || date > Date.current
      date
    rescue Date::Error
      raise ArgumentError, "Invalid ISO date"
    end

    def self.validate_source!(kind, entry, amount:, incurred:, currency:)
      return if kind == "paid_by_other" && entry.nil?
      raise ArgumentError, "Posted source bank entry required" unless entry
      EntryAllocation.validate_entry!(entry)
      raise ArgumentError, "Source is not matched to obligation" unless
        entry.date == incurred && entry.currency == currency && entry.amount.abs == amount &&
        (kind == "borrowed" ? entry.amount.negative? : entry.amount.positive?) &&
        entry.date <= Date.current
    end

    def net_settled_amount
      settlements.where(kind: %w[payment source_refund]).sum(:applied_amount) -
        settlements.where(kind: "refund").sum(:applied_amount)
    end

    def outstanding_amount
      return BigDecimal("0") if status == "cancelled"
      principal_amount - net_settled_amount
    end

    def consistent?
      return false unless debt_account.family_id == family_id &&
        debt_account.owner_id == owner_id && debt_account.currency == currency &&
        debt_account.accountable_type == (direction == "receivable" ? "OtherAsset" : "OtherLiability")
      self.class.validate_source!(kind, source_entry, amount: personal_amount + other_amount,
        incurred: incurred_on, currency: currency)
      settlements.all?(&:consistent?) && net_settled_amount.between?(0, principal_amount)
    rescue ArgumentError, ActiveRecord::RecordNotFound
      false
    end

    def cancel_for!(actor, version:)
      self.class.with_actor_for!(actor, id) do |record|
        raise Conflict, "Debt changed" unless version == record.lock_version
        raise Conflict, "Cannot cancel settled debt" if record.settlements.exists?
        record.update!(status: "cancelled", cancelled_at: Time.current)
        record.refresh_valuation!
        PlanningAuditEvent.record!(actor: actor, event_type: "personal_debt.cancelled", resource: record)
      end
    end

    def self.with_actor_for!(actor, id)
      StudyProject.with_actor(actor) do
        record = for_user(actor).lock.find(id)
        yield record
      end
    end

    def refresh_valuation!
      as_of = [ Date.current, incurred_on ].max
      entry = debt_account.entries.where(entryable_type: "Valuation", date: as_of).first
      value = status == "cancelled" ? BigDecimal("0") : outstanding_amount
      if entry
        entry.update!(amount: value)
      else
        debt_account.entries.create!(entryable: Valuation.new(kind: "reconciliation"),
          name: "Recorded personal #{direction}", amount: value,
          currency: currency, date: as_of)
      end
    end

    def payload
      { id: id, kind: kind, direction: direction, project_id: project_id,
        contact_nickname: contact_nickname, purpose: purpose, currency: currency,
        personal_amount: personal_amount.to_s("F"), other_amount: other_amount.to_s("F"),
        principal_amount: principal_amount.to_s("F"), outstanding_amount: outstanding_amount.to_s("F"),
        source_entry_id: source_entry_id, debt_account_id: debt_account_id,
        incurred_on: incurred_on.iso8601, due_on: due_on&.iso8601,
        status: status, consistent: consistent?, lock_version: lock_version }
    end

    private
      def valid_scope
        errors.add(:base, "Invalid debt tenant") unless
          owner && owner.family_id == family_id && debt_account && debt_account.family_id == family_id &&
          debt_account.owner_id == owner_id && (!project || (project.family_id == family_id && project.owner_id == owner_id)) &&
          (!source_entry || source_entry.account.family_id == family_id)
      end
  end
end
