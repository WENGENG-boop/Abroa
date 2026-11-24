class LinkAbroaFeeInstallmentsToSureOccurrences < ActiveRecord::Migration[8.1]
  def change
    add_reference :abroa_fee_installments, :recurring_occurrence,
      type: :uuid, null: true, index: { unique: true, name: "idx_abroa_fee_occurrence_once" },
      foreign_key: { on_delete: :nullify }
  end
end
