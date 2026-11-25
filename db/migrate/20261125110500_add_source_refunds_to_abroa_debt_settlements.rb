class AddSourceRefundsToAbroaDebtSettlements < ActiveRecord::Migration[8.1]
  OLD_CHECK = "kind IN ('payment','refund') AND native_amount > 0 AND applied_amount > 0 AND entry_amount > 0 AND " \
    "native_amount <> 'NaN'::numeric AND applied_amount <> 'NaN'::numeric AND entry_amount <> 'NaN'::numeric AND " \
    "((kind = 'payment' AND refunded_settlement_id IS NULL) OR (kind = 'refund' AND refunded_settlement_id IS NOT NULL))".freeze
  NEW_CHECK = "kind IN ('payment','refund','source_refund') AND native_amount > 0 AND applied_amount > 0 AND entry_amount > 0 AND " \
    "native_amount <> 'NaN'::numeric AND applied_amount <> 'NaN'::numeric AND entry_amount <> 'NaN'::numeric AND " \
    "((kind = 'payment' AND refunded_settlement_id IS NULL AND refund_link_id IS NULL) OR " \
    "(kind = 'refund' AND refunded_settlement_id IS NOT NULL AND refund_link_id IS NULL) OR " \
    "(kind = 'source_refund' AND refunded_settlement_id IS NULL AND refund_link_id IS NOT NULL))".freeze

  def up
    add_reference :abroa_debt_settlements, :refund_link, type: :uuid,
      foreign_key: { to_table: :abroa_refund_links, on_delete: :restrict }
    add_index :abroa_debt_settlements, [ :personal_debt_id, :refund_link_id ], unique: true,
      where: "refund_link_id IS NOT NULL", name: "idx_abroa_debt_source_refund_unique"
    remove_check_constraint :abroa_debt_settlements, name: "abroa_debt_settlement_valid"
    add_check_constraint :abroa_debt_settlements, NEW_CHECK, name: "abroa_debt_settlement_valid"
  end

  def down
    remove_check_constraint :abroa_debt_settlements, name: "abroa_debt_settlement_valid"
    add_check_constraint :abroa_debt_settlements, OLD_CHECK, name: "abroa_debt_settlement_valid"
    remove_index :abroa_debt_settlements, name: "idx_abroa_debt_source_refund_unique"
    remove_reference :abroa_debt_settlements, :refund_link,
      foreign_key: { to_table: :abroa_refund_links }
  end
end
