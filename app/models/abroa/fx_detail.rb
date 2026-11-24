module Abroa
  class FxDetail < ApplicationRecord
    self.table_name = "abroa_fx_details"
    Conflict = Class.new(StandardError)
    belongs_to :family
    belongs_to :actor, class_name: "User"
    belongs_to :transfer
    belongs_to :debit_entry, class_name: "Entry"
    belongs_to :credit_entry, class_name: "Entry"
    belongs_to :fee_entry, class_name: "Entry", optional: true
    validates :transfer_id, uniqueness: true
    validates :operation_key_digest, :request_digest, :exchanged_on, presence: true
    validate :ledger_consistency

    def self.create_for!(user, source_account_id:, destination_account_id:, date:, debit_amount:, credit_amount:, fee_amount: "0", fee_currency: nil, idempotency_key:)
      debit = Decimal.money!(debit_amount, positive: true)
      credit = Decimal.money!(credit_amount, positive: true)
      fee = Decimal.money!(fee_amount, nonnegative: true)
      fee_code = fee.positive? ? Decimal.currency!(fee_currency) : nil
      raise ArgumentError, "Fee currency requires a positive fee" if fee.zero? && fee_currency.present?
      raise ArgumentError, "Invalid exchange date" unless date.instance_of?(Date) && date.year.positive? && date <= Date.current
      unless idempotency_key.is_a?(String) && idempotency_key.present? && idempotency_key.bytesize <= 128
        raise ArgumentError, "Idempotency-Key must contain 1 to 128 bytes"
      end

      key = Digest::SHA256.hexdigest(idempotency_key)
      user.with_lock do
        raise ActiveRecord::RecordNotFound if !user.active? || user.guest?
        scope = user.family.accounts.writable_by(user)
        source, target = scope.find(source_account_id), scope.find(destination_account_id)
        raise ArgumentError, "Exchange requires different deposit accounts" if source.id == target.id
        accounts = user.family.accounts.where(id: [ source.id, target.id ]).order(:id).lock.index_by(&:id)
        source, target = accounts.fetch(source.id), accounts.fetch(target.id)
        unless [ source, target ].all? { |account| AccountPolicy.new(user, account).permits?(:write) }
          raise ActiveRecord::RecordNotFound
        end
        unless [ source, target ].all? { |account| account.accountable_type == "Depository" }
          raise ArgumentError, "Exchange requires two deposit accounts"
        end
        from, to = Decimal.currency!(source.currency), Decimal.currency!(target.currency)
        raise ArgumentError, "Exchange currencies must differ" if from == to
        raise ArgumentError, "Fee must use an account currency" if fee_code && ![ from, to ].include?(fee_code)
        rate = Decimal.rate!(credit / debit)
        unless (debit * rate).round(4) == credit
          raise ArgumentError, "Rate cannot preserve both amounts at stored precision"
        end
        digest = Digest::SHA256.hexdigest(JSON.generate([
          source.id, target.id, date.iso8601, debit.to_s("F"), credit.to_s("F"), fee.to_s("F"), fee_code, from, to
        ]))
        existing = find_by(actor: user, operation_key_digest: key)
        if existing
          unless existing.family_id == user.family_id && existing.request_digest == digest && existing.consistent?
            raise Conflict, "Exchange request or ledger has changed"
          end
          next existing
        end

        transfer = Transfer::Creator.new(
          family: user.family, source_account_id: source.id, destination_account_id: target.id,
          date: date, amount: debit, exchange_rate: rate,
          source_fee_amount: fee_code == from ? fee : 0,
          destination_fee_amount: fee_code == to ? fee : 0,
          idempotency_key: "abroa-fx-#{Digest::SHA256.hexdigest("#{user.id}:#{key}")}"
        ).create
        debit_entry = transfer.outflow_transaction.entry.reload
        credit_entry = transfer.inflow_transaction.entry.reload
        fee_entry = transfer.fee_transactions.first&.entry&.reload
        create!(
          family: user.family, actor: user, transfer: transfer, debit_entry: debit_entry,
          credit_entry: credit_entry, fee_entry: fee_entry, debit_amount: debit,
          credit_amount: credit, debit_currency: from, credit_currency: to,
          fee_amount: fee, fee_currency: fee_code, actual_rate: rate, exchanged_on: date,
          operation_key_digest: key, request_digest: digest
        )
      end
    end

    def self.visible_to!(user, id)
      detail = where(family: user.family).find(id)
      unless [ detail.debit_entry.account, detail.credit_entry.account ].all? { |account| AccountPolicy.new(user, account).show? }
        raise ActiveRecord::RecordNotFound
      end
      detail
    end

    def consistent?
      return false unless transfer && debit_entry && credit_entry && debit_amount && credit_amount && fee_amount
      return false unless transfer.confirmed? &&
        transfer.outflow_transaction.entry.id == debit_entry_id &&
        transfer.inflow_transaction.entry.id == credit_entry_id
      return false unless debit_entry.account.family_id == family_id && credit_entry.account.family_id == family_id
      return false unless debit_entry.amount == debit_amount && credit_entry.amount == -credit_amount &&
        debit_entry.currency == debit_currency && credit_entry.currency == credit_currency &&
        debit_entry.date == exchanged_on && credit_entry.date == exchanged_on &&
        debit_entry.transaction.kind == "funds_movement" && credit_entry.transaction.kind == "funds_movement"
      return false unless Decimal.rate!(credit_amount / debit_amount) == actual_rate

      if fee_amount.positive?
        transfer.fee_transactions.count == 1 && fee_entry && fee_entry.account_id.in?([ debit_entry.account_id, credit_entry.account_id ]) &&
          transfer.fee_transactions.exists?(id: fee_entry.entryable_id) &&
          fee_entry.amount == fee_amount && fee_entry.currency == fee_currency &&
          fee_entry.date == exchanged_on && fee_entry.transaction.kind == "standard"
      else
        fee_entry.nil? && fee_currency.nil? && transfer.fee_transactions.none?
      end
    rescue ArgumentError, ZeroDivisionError, NoMethodError
      false
    end

    def payload
      {
        id: id, transfer_id: transfer_id, debit_entry_id: debit_entry_id, credit_entry_id: credit_entry_id,
        fee_entry_id: fee_entry_id, debit_amount: debit_amount.to_s("F"), credit_amount: credit_amount.to_s("F"),
        debit_currency: debit_currency, credit_currency: credit_currency,
        fee_amount: fee_amount.to_s("F"), fee_currency: fee_currency,
        actual_rate: actual_rate.to_s("F"), exchanged_on: exchanged_on.iso8601, consistent: consistent?
      }
    end

    def readonly?
      persisted? || super
    end

    private
      def ledger_consistency
        errors.add(:actor, :invalid) unless actor && actor.family_id == family_id
        errors.add(:transfer, "does not match the recorded exchange") unless consistent?
      end
  end
end
