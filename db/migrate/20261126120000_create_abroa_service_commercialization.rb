class CreateAbroaServiceCommercialization < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_service_plans, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.boolean :enabled, null: false, default: true
      t.jsonb :entitlements, null: false, default: {}
      t.decimal :price_amount, precision: 20, scale: 6
      t.string :price_currency
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index :code, unique: true
    end
    add_check_constraint :abroa_service_plans,
      "(price_amount IS NULL AND price_currency IS NULL) OR " \
        "(price_amount IS NOT NULL AND price_currency IS NOT NULL AND price_amount >= 0)",
      name: "abroa_service_plan_price_consistent"

    create_table :abroa_service_subscriptions, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false,
        foreign_key: { on_delete: :restrict }, index: { unique: true }
      t.references :plan, type: :uuid, null: false,
        foreign_key: { to_table: :abroa_service_plans, on_delete: :restrict }
      t.string :status, null: false
      t.string :origin, null: false
      t.datetime :started_at, null: false
      t.datetime :ends_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :abroa_service_subscriptions,
      "status IN ('active','trialing','paused','canceled')",
      name: "abroa_service_subscription_valid_state"

    create_table :abroa_service_subscription_events, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :service_subscription, type: :uuid, null: false,
        foreign_key: { to_table: :abroa_service_subscriptions, on_delete: :restrict },
        index: { name: "idx_abroa_subscription_events_owner" }
      t.uuid :actor_user_id
      t.string :action, null: false
      t.string :before_status
      t.string :after_status, null: false
      t.string :previous_plan
      t.string :new_plan, null: false
      t.string :request_id, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
      t.index [ :service_subscription_id, :occurred_at ], name: "idx_abroa_service_subscription_history"
    end

    create_table :abroa_service_usage_events, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :restrict }
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :restrict }
      t.string :feature, null: false
      t.string :source, null: false
      t.string :event_id, null: false
      t.integer :quantity, null: false
      t.date :period_start, null: false
      t.datetime :occurred_at, null: false
      t.decimal :cost_amount, precision: 20, scale: 6
      t.string :cost_currency
      t.timestamps
      t.index [ :user_id, :feature, :event_id ], unique: true, name: "idx_abroa_usage_dedupe"
      t.index [ :period_start, :feature ], name: "idx_abroa_usage_period"
    end
    add_check_constraint :abroa_service_usage_events, "quantity > 0",
      name: "abroa_usage_positive_quantity"
    add_check_constraint :abroa_service_usage_events,
      "(cost_amount IS NULL AND cost_currency IS NULL) OR " \
        "(cost_amount IS NOT NULL AND cost_currency IS NOT NULL AND cost_amount >= 0)",
      name: "abroa_usage_cost_consistent"

    create_table :abroa_service_quota_counters, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :feature, null: false
      t.date :period_start, null: false
      t.bigint :used_count, null: false, default: 0
      t.timestamps
      t.index [ :user_id, :feature, :period_start ], unique: true, name: "idx_abroa_quota_user_period"
    end
    add_check_constraint :abroa_service_quota_counters, "used_count >= 0",
      name: "abroa_quota_nonnegative"

    create_table :abroa_service_billing_events, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :restrict }
      t.references :service_subscription, type: :uuid, null: false,
        foreign_key: { to_table: :abroa_service_subscriptions, on_delete: :restrict },
        index: { name: "idx_abroa_billing_subscription" }
      t.string :external_id, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "simulated"
      t.datetime :occurred_at, null: false
      t.decimal :amount, precision: 20, scale: 6
      t.string :currency
      t.timestamps
      t.index [ :user_id, :external_id ], unique: true, name: "idx_abroa_billing_event_dedupe"
    end
    add_check_constraint :abroa_service_billing_events,
      "(amount IS NULL AND currency IS NULL) OR " \
        "(amount IS NOT NULL AND currency IS NOT NULL AND amount >= 0)",
      name: "abroa_billing_cost_consistent"
  end
end
