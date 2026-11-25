class AddAbroaFundingReversalLedgerEvidence < ActiveRecord::Migration[8.1]
  def change
    add_column :abroa_funding_reversals, :entry_amount, :decimal,
      precision: 19, scale: 4, null: false
    add_column :abroa_funding_reversals, :entry_currency, :string, null: false
    add_check_constraint :abroa_funding_reversals,
      "entry_amount > 0 AND entry_amount <> 'NaN'::numeric",
      name: "abroa_reversal_original_entry_amount_positive"
  end
end
