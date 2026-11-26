# PostgreSQL-only audit triggers are not represented in Rails' Ruby schema.rb.
# Ensure fresh installations and test database resets retain append-only audit.
namespace :abroa do
  desc "Ensure P5 platform audit events are immutable at the database layer"
  task ensure_platform_audit_trigger: :environment do
    Abroa::PlatformAuditEvent.ensure_storage_protected!
  end
end

%w[db:prepare db:test:prepare db:schema:load].each do |name|
  next unless Rake::Task.task_defined?(name)

  Rake::Task[name].enhance do
    Rake::Task["abroa:ensure_platform_audit_trigger"].reenable
    Rake::Task["abroa:ensure_platform_audit_trigger"].invoke
  end
end
