module Abroa
  # One predicate for both Sure's builtin chat tool caller and its MCP registry.
  # For Abroa users the old write tools do not have the P4 two-step confirmation
  # protocol; only read-only tools can be listed or executed through AI.
  class AiLegacyToolGuard
    MUTATING_PREFIXES = /\A(?:create|update|delete|apply|set|record|import|upload|match|unmatch|review)_/.freeze

    def self.mutating?(name)
      name.to_s.match?(MUTATING_PREFIXES)
    end

    def self.abroa_role_active?(user)
      return false unless user&.active? && !user.guest?
      profile = Profile.find_by(user_id: user.id)
      profile && (profile.student_enabled? || profile.parent_enabled?)
    end

    def self.confirmation_required?(user, name)
      mutating?(name) && abroa_role_active?(user)
    end
  end
end
