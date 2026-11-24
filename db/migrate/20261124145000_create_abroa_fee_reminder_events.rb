class CreateAbroaFeeReminderEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_fee_reminder_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :recipient, null: false, type: :uuid, foreign_key: { to_table: :users }
      t.references :fee_installment, null: false, type: :uuid,
        foreign_key: { to_table: :abroa_fee_installments }
      t.string :kind, null: false
      t.date :due_on, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
      t.index [ :fee_installment_id, :kind, :due_on ], unique: true,
        name: "idx_abroa_unique_fee_reminder"
      t.index [ :family_id, :recipient_id, :occurred_at ], name: "idx_abroa_fee_reminder_inbox"
    end
    add_check_constraint :abroa_fee_reminder_events,
      "kind IN ('due_soon','overdue')", name: "abroa_fee_reminder_kind"
  end
end
