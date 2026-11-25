class CreateAbroaNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_notification_preferences, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :user, null: false, type: :uuid,
        foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.boolean :email_enabled, null: false, default: false
      t.boolean :in_app_enabled, null: false, default: true
      t.string :timezone, null: false, default: "UTC"
      t.integer :quiet_start_hour
      t.integer :quiet_end_hour
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end
    add_check_constraint :abroa_notification_preferences,
      "((quiet_start_hour IS NULL AND quiet_end_hour IS NULL) OR " \
      "(quiet_start_hour BETWEEN 0 AND 23 AND quiet_end_hour BETWEEN 0 AND 23))",
      name: "abroa_notification_quiet_hours"

    create_table :abroa_inbox_notifications, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :recipient, type: :uuid, null: false,
        foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :family, type: :uuid, null: false,
        foreign_key: { on_delete: :cascade }
      t.string :event_kind, null: false
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.string :event_key_digest, null: false
      t.datetime :occurred_at, null: false
      t.datetime :read_at
      t.string :state, null: false, default: "unread"
      t.timestamps
      t.index [ :recipient_id, :event_key_digest ],
        unique: true, name: "idx_abroa_inbox_event_dedup"
      t.index [ :recipient_id, :created_at ], name: "idx_abroa_inbox_recency"
    end
    add_check_constraint :abroa_inbox_notifications,
      "state IN ('unread','read')", name: "abroa_inbox_state"

    create_table :abroa_email_outboxes, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :inbox_notification, null: false, type: :uuid,
        index: { unique: true },
        foreign_key: { to_table: :abroa_inbox_notifications, on_delete: :restrict }
      t.references :recipient, null: false, type: :uuid,
        foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :family, null: false, type: :uuid,
        foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.datetime :next_retry_at
      t.datetime :sent_at
      t.string :error_code
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :status, :next_retry_at ]
    end
    add_check_constraint :abroa_email_outboxes,
      "status IN ('pending','sending','sent','failed','cancelled','uncertain') AND " \
      "attempt_count >= 0", name: "abroa_outbox_delivery_state"
  end
end
