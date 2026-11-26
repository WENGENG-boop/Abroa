class ProtectAbroaPlatformAuditEvents < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION abroa_platform_audit_immutable() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'Abroa platform audit is append-only';
      END
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER abroa_platform_audit_no_mutation
      BEFORE UPDATE OR DELETE ON abroa_platform_audit_events
      FOR EACH ROW EXECUTE FUNCTION abroa_platform_audit_immutable();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS abroa_platform_audit_no_mutation ON abroa_platform_audit_events;
      DROP FUNCTION IF EXISTS abroa_platform_audit_immutable();
    SQL
  end
end
