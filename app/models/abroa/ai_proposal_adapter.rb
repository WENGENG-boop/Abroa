module Abroa
  # Explicit allowlisted adapters from a human-confirmed AI proposal to the
  # already-reviewed P2 business APIs. They cannot mutate arbitrary attributes.
  class AiProposalAdapter
    EXECUTABLE = %w[budget_update fee_adjust pool_allocate].freeze
    MAX_AMOUNT = BigDecimal("100000000000")

    def self.resource_for!(actor, operation, id)
      raise ArgumentError, "Invalid operation" unless EXECUTABLE.include?(operation)
      raise ActiveRecord::RecordNotFound unless UuidFormat.valid?(id)
      case operation
      when "budget_update" then BudgetNode.for_user(actor).find(id)
      when "fee_adjust" then FeePlan.for_user(actor).find(id)
      when "pool_allocate" then FundPool.for_user(actor).find(id)
      end
    end

    def self.prepare!(actor, operation:, resource_id:, parameters:)
      resource = resource_for!(actor, operation, resource_id)
      resource.project.ensure_writable!
      raise ArgumentError, "Expected object" unless parameters.is_a?(Hash)
      params = parameters.deep_stringify_keys
      normalized = case operation
      when "budget_update"
        raise ArgumentError, "Only budget limit may change" unless params.keys == [ "limit_amount" ]
        raise ArgumentError, "Inactive budget" unless resource.status == "active"
        { "limit_amount" => amount!(params.fetch("limit_amount")) }
      when "fee_adjust"
        raise ArgumentError, "Invalid fee adjustment" unless
          (params.keys.sort - %w[amount installment_id kind reason]).empty? &&
          %w[amount kind reason].all? { |name| params.key?(name) }
        raise ArgumentError, "Inactive fee" unless resource.status == "active"
        kind = params["kind"]
        raise ArgumentError, "Invalid adjustment kind" unless FeeAdjustment::KINDS.include?(kind)
        reason = params["reason"]
        raise ArgumentError, "Invalid reason" unless reason.is_a?(String) &&
          reason.strip.length.between?(1, 500)
        installment = params["installment_id"]
        if installment
          raise ActiveRecord::RecordNotFound unless UuidFormat.valid?(installment)
          resource.installments.find(installment)
        end
        { "kind" => kind, "amount" => amount!(params.fetch("amount")),
          "reason" => reason.strip, "installment_id" => installment }
      when "pool_allocate"
        raise ArgumentError, "Only direct allocation is allowed" unless
          params.keys.sort == %w[account_id amount]
        raise ArgumentError, "Inactive pool" unless resource.status == "active" && resource.goal_id.nil?
        account = account_for!(actor, resource, params.fetch("account_id"))
        raise ArgumentError, "Currency mismatch" unless account.currency == resource.currency
        { "account_id" => account.id, "amount" => amount!(params.fetch("amount")) }
      end
      {
        resource: resource, parameters: normalized,
        before: before_snapshot(resource, operation, normalized),
        state_digest: state_digest(actor, resource, operation, normalized)
      }
    end

    def self.amount!(value)
      amount = Decimal.money!(value, positive: true)
      raise ArgumentError, "Amount exceeds safety bound" if amount > MAX_AMOUNT
      amount.to_s("F")
    end

    def self.account_for!(user, pool, id)
      raise ActiveRecord::RecordNotFound unless UuidFormat.valid?(id)
      account = user.family.accounts.writable_by(user).where(
        accountable_type: "Depository", owner_id: user.id).find(id)
      raise ActiveRecord::RecordNotFound unless
        ProjectAccount.where(project_id: pool.project_id, account_id: account.id,
          family_id: pool.family_id).exists?
      account
    end

    def self.before_snapshot(resource, operation, params)
      case operation
      when "budget_update"
        { "limit_amount" => resource.limit_amount.to_s("F") }
      when "fee_adjust"
        { "amount_due" => resource.amount_due.to_s("F"),
          "paid_amount" => resource.paid_amount.to_s("F"),
          "outstanding_amount" => resource.outstanding_amount.to_s("F") }
      when "pool_allocate"
        account = Account.find(params.fetch("account_id"))
        { "currency" => resource.currency,
          "allocated" => resource.native_allocated_for(account).to_s("F"),
          "reserved" => resource.native_reserved_for(account).to_s("F"),
          "account_balance" => account.balance.to_s("F") }
      end
    end

    def self.state_digest(actor, resource, operation, params)
      data = case operation
      when "budget_update"
        [ resource.lock_version, resource.status, resource.limit_amount.to_s("F") ]
      when "fee_adjust"
        [ resource.lock_version, resource.status, resource.amount_due.to_s("F"),
          resource.paid_amount.to_s("F"), resource.outstanding_amount.to_s("F"),
          resource.installments.order(:id).map do |installment|
            [ installment.id, installment.lock_version,
              installment.net_amount.to_s("F"), installment.paid_amount.to_s("F") ]
          end,
          FeeAdjustment.for_user(actor).where(fee_plan_id: resource.id)
            .order(:id).pluck(:id, :kind, :amount, :status, :updated_at) ]
      when "pool_allocate"
        account = account_for!(actor, resource, params.fetch("account_id"))
        [ resource.lock_version, resource.status, resource.goal_id,
          account.id, account.updated_at&.to_f, account.balance.to_s("F"),
          resource.native_allocated_for(account).to_s("F"),
          resource.native_reserved_for(account).to_s("F"),
          resource.movements.where(account_id: account.id).order(:id)
            .pluck(:id, :kind, :amount, :reserved_released_amount) ]
      end
      Digest::SHA256.hexdigest(JSON.generate(data))
    end

    def self.execute!(actor, proposal, resource)
      params = proposal.parameters
      case proposal.operation
      when "budget_update"
        result = BudgetNode.change_for!(actor, resource.id,
          version: resource.lock_version,
          attributes: { limit_amount: params.fetch("limit_amount") })
      when "fee_adjust"
        result = FeeAdjustment.apply_for!(actor, resource.id,
          kind: params.fetch("kind"), amount: params.fetch("amount"),
          reason: params.fetch("reason"),
          installment_id: params["installment_id"],
          key: "ai:#{proposal.id}")
      when "pool_allocate"
        result = PoolMovement.apply_for!(actor, resource.id,
          account_id: params.fetch("account_id"), kind: "allocate",
          amount: params.fetch("amount"), key: "ai:#{proposal.id}")
      end
      resource.reload
      { execution_id: result.id, resource_version: resource.lock_version,
        state_digest: state_digest(actor, resource, proposal.operation, params) }
    end

    def self.compensate!(actor, proposal, resource)
      params = proposal.parameters
      case proposal.operation
      when "budget_update"
        BudgetNode.change_for!(actor, resource.id, version: resource.lock_version,
          attributes: { limit_amount: proposal.before_snapshot.fetch("limit_amount") })
      when "fee_adjust"
        adjustment = FeeAdjustment.for_user(actor).where(
          fee_plan_id: resource.id).find(proposal.execution_resource_id)
        raise AiOperationProposal::Conflict, "Adjustment already modified" unless
          adjustment.status == "approved"
        FeeAdjustment.void_for!(actor, id: adjustment.id)
      when "pool_allocate"
        movement = PoolMovement.where(family_id: actor.family_id, pool_id: resource.id)
          .find(proposal.execution_resource_id)
        raise AiOperationProposal::Conflict, "Not an AI allocation" unless
          movement.kind == "allocate" && movement.account_id == params.fetch("account_id") &&
          movement.amount == BigDecimal(params.fetch("amount"))
        PoolMovement.apply_for!(actor, resource.id,
          account_id: params.fetch("account_id"), kind: "release",
          amount: params.fetch("amount"), key: "ai:compensate:#{proposal.id}")
      end
    end
  end
end
