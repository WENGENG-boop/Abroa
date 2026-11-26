class Abroa::PlatformRoleAssignment < ApplicationRecord
  self.table_name = "abroa_platform_role_assignments"
  ROLES = %w[operator access_admin system_admin].freeze
  ROLE_PERMISSIONS = {
    "operator" => %w[users.read operations.read],
    "access_admin" => %w[users.read users.suspend operations.read],
    "system_admin" => %w[users.read users.suspend roles.manage operations.read operations.write]
  }.freeze

  belongs_to :user
  belongs_to :granted_by, class_name: "User", optional: true

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :role, uniqueness: { scope: :user_id }

  # Read directly from PostgreSQL on every request. Neither Sure super_admin
  # nor a cached family role ever confers a platform permission.
  def self.permitted?(user, permission)
    return false unless user&.persisted?
    return false unless User.where(id: user.id, active: true, platform_suspended_at: nil).exists?

    roles = ROLE_PERMISSIONS.filter_map { |role, abilities| role if abilities.include?(permission.to_s) }
    roles.any? && where(user_id: user.id, role: roles).exists?
  end
end
