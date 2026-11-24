module Abroa
  # The goal_id link is a view of the EXISTING Sure Goal reservation. A linked
  # goal never creates an independent allocation ledger or a second claim.
  class FundPool < ApplicationRecord
    self.table_name = "abroa_fund_pools"
    Conflict = Class.new(StandardError)
    KINDS = %w[tuition rent living emergency savings insurance travel custom].freeze
    FIELDS = %i[name kind currency target_amount goal_id].freeze

    belongs_to :family
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :goal, class_name: "Goal", optional: true
    has_many :movements, class_name: "Abroa::PoolMovement", foreign_key: :pool_id

    validates :name, :kind, :currency, presence: true
    validates :name, length: { maximum: 255 }
    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: %w[active archived] }
    validate :valid_tenant_and_goal
    validate :valid_target
    before_validation { self.currency = Decimal.currency!(currency) if currency.present? }

    def self.for_user(user)
      where(project_id: StudyProject.for_user(user).select(:id), family_id: user.family_id)
    end

    def self.create_for!(user, project_id, attributes:, key: nil)
      fields = checked(attributes)
      raise ArgumentError, "Idempotency-Key invalid" if key && (!key.is_a?(String) || key.empty? || key.bytesize > 128)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        digest = key && Digest::SHA256.hexdigest(key)
        request_digest = Digest::SHA256.hexdigest(JSON.generate(fields.deep_stringify_keys.sort.to_h))
        if digest && (existing = project.fund_pools.find_by(creation_key_digest: digest))
          raise Conflict, "Fund pool key changed" unless existing.creation_request_digest == request_digest
          next existing
        end
        if fields[:goal_id]
          goal = user.family.goals.find(fields[:goal_id])
          raise ActiveRecord::RecordNotFound unless goal.goal_accounts.all? { |link|
            user.family.accounts.accessible_by(user).where(id: link.account_id).exists?
          }
        end
        record = project.fund_pools.create!(fields.merge(family: user.family,
          creation_key_digest: digest, creation_request_digest: digest && request_digest))
        PlanningAuditEvent.record!(actor: user, event_type: "fund_pool.created", resource: record)
        record
      end
    end

    def self.checked(attributes)
      values = attributes.symbolize_keys
      raise ArgumentError, "Unknown fund pool field" unless (values.keys - FIELDS).empty?
      values
    end

    def self.change_for!(user, id, version:, attributes:)
      fields = checked(attributes)
      StudyProject.with_actor(user) do
        pool = for_user(user).lock.find(id)
        raise Conflict, "Fund pool changed" unless version.is_a?(Integer) && pool.lock_version == version
        raise Conflict, "Fund pool is archived" unless pool.status == "active"
        pool.project.ensure_writable!
        if (fields.keys & %i[goal_id currency]).any? && pool.movements.exists?
          raise Conflict, "Cannot change funding source or currency after allocation"
        end
        if fields.key?(:goal_id) && fields[:goal_id]
          goal = user.family.goals.find(fields[:goal_id])
          raise ActiveRecord::RecordNotFound unless goal.goal_accounts.all? { |link|
            user.family.accounts.accessible_by(user).where(id: link.account_id).exists?
          }
        end
        pool.update!(fields)
        PlanningAuditEvent.record!(actor: user, event_type: "fund_pool.updated", resource: pool)
        pool
      end
    end

    def self.archive_for!(user, id, version:)
      change_state_for!(user, id, version: version, state: "archived")
    end

    def self.restore_for!(user, id, version:)
      change_state_for!(user, id, version: version, state: "active")
    end

    def self.change_state_for!(user, id, version:, state:)
      StudyProject.with_actor(user) do
        pool = for_user(user).lock.find(id)
        raise Conflict, "Fund pool changed" unless version.is_a?(Integer) && version == pool.lock_version
        pool.project.ensure_writable! if state == "active"
        raise Conflict, "Already in requested state" if pool.status == state
        pool.update!(status: state, archived_at: state == "archived" ? Time.current : nil)
        PlanningAuditEvent.record!(actor: user, event_type: "fund_pool.#{state}", resource: pool)
        pool
      end
    end

    def native_allocated_for(account)
      if goal_id
        return BigDecimal("0") if Goal::RELEASED_STATES.include?(goal.state)
        link = goal.goal_accounts.find_by(account_id: account.id)
        return BigDecimal("0") unless link
        link.allocated_amount || [ BigDecimal("0"), account.balance ].max
      else
        movements.where(account_id: account.id).sum(
          "CASE WHEN kind IN ('allocate','refund') THEN amount WHEN kind IN ('release','consume') THEN -amount ELSE 0 END").to_d
      end
    end

    def native_reserved_for(account)
      movements.where(account_id: account.id).sum(
        "CASE WHEN kind = 'reserve' THEN amount WHEN kind = 'unreserve' THEN -amount WHEN kind = 'consume' THEN -reserved_released_amount ELSE 0 END").to_d
    end

    def native_free_for(account)
      native_allocated_for(account) - native_reserved_for(account)
    end

    def accounts_for(user)
      ids = movements.select(:account_id)
      ids = Account.where(id: ids).or(Account.where(id: goal.goal_accounts.select(:account_id))) if goal_id
      user.family.accounts.accessible_by(user).where(id: ids)
    end

    def payload_for(user)
      sources = accounts_for(user).order(:id).limit(101).to_a
      raise ArgumentError, "Too many pool accounts" if sources.size > 100
      native = sources.map do |account|
        {
          account_id: account.id, currency: account.currency,
          allocated: native_allocated_for(account).to_s("F"),
          reserved_for_fees: native_reserved_for(account).to_s("F"),
          free: native_free_for(account).to_s("F"),
          shortfall: AllocationGuard.summary(account)[:shortfall].to_s("F")
        }
      end
      { id: id, project_id: project_id, goal_id: goal_id, name: name, kind: kind,
        currency: currency, target_amount: target_amount&.to_s("F"), status: status,
        archived_at: archived_at&.iso8601(6), lock_version: lock_version, accounts: native }
    end

    private
      def valid_target
        Decimal.money!(target_amount, nonnegative: true) if target_amount
      rescue ArgumentError
        errors.add(:target_amount, :invalid)
      end

      def valid_tenant_and_goal
        errors.add(:project, :invalid) unless project && project.family_id == family_id
        if goal && (goal.family_id != family_id || Goal::RELEASED_STATES.include?(goal.state))
          errors.add(:goal, :invalid)
        end
      end
  end
end
