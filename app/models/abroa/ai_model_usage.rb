module Abroa
  class AiModelUsage < ApplicationRecord
    self.table_name = "abroa_ai_model_usages"

    belongs_to :family
    belongs_to :owner, class_name: "User"
    belongs_to :provider, class_name: "Abroa::AiModelProvider", optional: true
    validates :status, inclusion: { in: %w[success failed timeout] }
    validates :model_identifier, presence: true
    validate :valid_scope

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active?
      where(owner_id: user.id, family_id: user.family_id)
    end

    def self.record!(user, provider:, status:, input_tokens: nil,
      output_tokens: nil, cost_usd: nil, latency_ms: nil, failure_kind: nil)
      raise ArgumentError, "Invalid usage status" unless %w[success failed timeout].include?(status)
      attrs = { input_tokens: input_tokens, output_tokens: output_tokens, latency_ms: latency_ms }
      attrs.each do |name, value|
        next if value.nil?
        raise ArgumentError, "Invalid usage counter" unless value.is_a?(Integer) &&
          value.between?(0, 100_000_000)
      end
      amount = cost_usd.nil? ? nil : Decimal.money!(cost_usd, nonnegative: true)
      create!(owner: user, family: user.family, provider: provider,
        model_identifier: provider.model_identifier, status: status,
        input_tokens: input_tokens, output_tokens: output_tokens,
        cost_usd: amount, latency_ms: latency_ms,
        failure_kind: failure_kind&.to_s&.slice(0, 80))
    end

    def self.summary_for(user)
      scope = for_user(user)
      total = scope.count
      succeeded = scope.where(status: "success").count
      provider = AiModelProvider.for_user(user).first
      limits = provider&.capabilities || {}
      call_limit = limits["monthly_call_quota"]
      token_limit = limits["monthly_token_quota"]
      quota = if call_limit || token_limit
        current_month = scope.where(created_at: Time.current.beginning_of_month..)
        used_calls = current_month.count
        used_tokens = current_month.sum(:input_tokens) + current_month.sum(:output_tokens)
        {
          source: "user_configured", month_calls: used_calls,
          calls_limit: call_limit, calls_remaining: call_limit ? [ call_limit - used_calls, 0 ].max : nil,
          month_tokens: used_tokens, tokens_limit: token_limit,
          tokens_remaining: token_limit ? [ token_limit - used_tokens, 0 ].max : nil
        }
      end
      {
        calls: total, success_count: succeeded,
        success_rate: total.positive? ? (BigDecimal(succeeded.to_s) / total * 100).round(2).to_s("F") : nil,
        input_tokens: scope.sum(:input_tokens),
        output_tokens: scope.sum(:output_tokens),
        cost_usd: scope.where.not(cost_usd: nil).exists? ? scope.sum(:cost_usd).to_s("F") : nil,
        unknown_cost_count: scope.where(cost_usd: nil).count,
        quota: quota
      }
    end

    private
      def valid_scope
        errors.add(:family, :invalid) unless owner && owner.family_id == family_id &&
          (!provider || (provider.owner_id == owner_id && provider.family_id == family_id))
      end
  end
end
