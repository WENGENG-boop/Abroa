class Abroa::PlatformAuditEvent < ApplicationRecord
  self.table_name = "abroa_platform_audit_events"
  ACTIONS = %w[role_grant role_revoke user_suspend user_unsuspend].freeze
  OUTCOMES = %w[granted revoked suspended unsuspended denied conflict].freeze

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :outcome, presence: true, inclusion: { in: OUTCOMES }
  validates :request_id, :occurred_at, presence: true

  # Ruby-format schema dumps do not include PostgreSQL triggers. Install this
  # safeguard after db:prepare/db:test:prepare as well as via the P5 migration.
  # It never executes during a web request, and it is safe to repeat.
  def self.ensure_storage_protected!
    return false unless connection.data_source_exists?(table_name)

    connection.execute(<<~SQL)
      CREATE OR REPLACE FUNCTION abroa_platform_audit_immutable() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'Abroa platform audit is append-only';
      END
      $$ LANGUAGE plpgsql;
      CREATE OR REPLACE TRIGGER abroa_platform_audit_no_mutation
      BEFORE UPDATE OR DELETE ON abroa_platform_audit_events
      FOR EACH ROW EXECUTE FUNCTION abroa_platform_audit_immutable();
    SQL
    true
  end

  # Security events are append-only. IDs persist if an account is erased;
  # logs must never contain emails, bank records, secrets or input payloads.
  def readonly?
    persisted? || super
  end

  def destroy
    raise ActiveRecord::ReadOnlyRecord, "Platform security audit records are immutable"
  end

  def destroy!
    raise ActiveRecord::ReadOnlyRecord, "Platform security audit records are immutable"
  end
end
