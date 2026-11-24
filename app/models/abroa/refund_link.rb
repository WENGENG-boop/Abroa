module Abroa
  class RefundLink < ApplicationRecord
    self.table_name = "abroa_refund_links"
    Conflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :original_entry, class_name: "Entry", optional: true
    belongs_to :refund_entry, class_name: "Entry", optional: true
    belongs_to :rate_snapshot, class_name: "Abroa::RateSnapshot", optional: true
    belongs_to :actor, class_name: "User", optional: true
    belongs_to :revoked_by, class_name: "User", optional: true
    scope :active, -> { where(revoked_at: nil) }

    validates :applied_amount, :refund_amount, numericality: { greater_than: 0 }
    validate :valid_initial_link, on: :create

    # Only connects actual ledger movements. Never creates a refund, removes
    # the original purchase, or changes a manually selected category.
    def self.link_for!(user, original_entry_id:, refund_entry_id:, applied_amount:, refund_amount:, rate_snapshot_id: nil)
      applied = Decimal.money!(applied_amount, positive: true)
      refunded = Decimal.money!(refund_amount, positive: true)
      raise ArgumentError, "Refund and original must differ" if original_entry_id == refund_entry_id

      with_actor(user) do |family|
        original, refund = locked_pair!(user, family, original_entry_id, refund_entry_id)
        snapshot = rate_snapshot_id && RateSnapshot.where(family: family).find(rate_snapshot_id)
        validate_pair!(original, refund)
        validate_conversion!(original, refund, applied, refunded, snapshot)
        existing = find_by(family: family, original_entry_key: original.id, refund_entry_key: refund.id)
        if existing
          unless !existing.revoked_at? && existing.applied_amount == applied &&
              existing.refund_amount == refunded && existing.rate_snapshot_id == snapshot&.id && existing.consistent?
            raise Conflict, "Refund allocation has changed or was revoked"
          end
          next existing
        end
        related = active.where(family: family).where("original_entry_id = ? OR refund_entry_id = ?", original.id, refund.id)
        unless related.all?(&:consistent?)
          raise Conflict, "A related refund requires reconciliation"
        end
        used_original = active.where(family: family, original_entry: original).sum(:applied_amount)
        used_refund = active.where(family: family, refund_entry: refund).sum(:refund_amount)
        if used_original + applied > original.amount || used_refund + refunded > refund.amount.abs
          raise ArgumentError, "Refund exceeds the unallocated original or refund amount"
        end

        create!(family: family, actor: user, original_entry: original, refund_entry: refund,
          original_entry_key: original.id, refund_entry_key: refund.id, rate_snapshot: snapshot,
          applied_amount: applied, refund_amount: refunded, currency: original.currency,
          refund_currency: refund.currency, original_date: original.date, refund_date: refund.date)
      end
    end

    def self.unlink_for!(user, id)
      with_actor(user) do |family|
        link = where(family: family).find(id)
        locked_pair!(user, family, link.original_entry_id, link.refund_entry_id)
        link.lock!
        link.update!(revoked_at: Time.current, revoked_by: user) unless link.revoked_at?
        link
      end
    end

    def self.visible_to!(user, id)
      link = where(family: user.family).find(id)
      accounts = [ link.original_entry&.account, link.refund_entry&.account ]
      unless accounts.all? { |account| account && AccountPolicy.new(user, account).show? }
        raise ActiveRecord::RecordNotFound
      end
      link
    end

    def consistent?
      return false unless original_entry && refund_entry
      self.class.send(:validate_pair!, original_entry, refund_entry)
      self.class.send(:validate_conversion!, original_entry, refund_entry, applied_amount, refund_amount, rate_snapshot)
      return false unless original_entry.id == original_entry_key && refund_entry.id == refund_entry_key &&
        original_entry.account.family_id == family_id && refund_entry.account.family_id == family_id &&
        original_entry.currency == currency && refund_entry.currency == refund_currency &&
        original_entry.date == original_date && refund_entry.date == refund_date
      self.class.active.where(family_id: family_id, original_entry_id: original_entry_id).sum(:applied_amount) <= original_entry.amount &&
        self.class.active.where(family_id: family_id, refund_entry_id: refund_entry_id).sum(:refund_amount) <= refund_entry.amount.abs
    rescue ArgumentError
      false
    end

    def remaining_original_amount
      return nil unless original_entry
      links = self.class.active.where(family_id: family_id, original_entry_id: original_entry_id)
      return nil unless links.all?(&:consistent?)
      original_entry.amount - links.sum(:applied_amount)
    end

    def payload
      { id: id, original_entry_id: original_entry_id, refund_entry_id: refund_entry_id,
        applied_amount: applied_amount.to_s("F"), refund_amount: refund_amount.to_s("F"),
        currency: currency, refund_currency: refund_currency, refund_date: refund_date.iso8601,
        rate_snapshot_id: rate_snapshot_id, revoked_at: revoked_at&.iso8601(6),
        consistent: consistent?, remaining_original_amount: remaining_original_amount&.to_s("F") }
    end

    class << self
      private
        def with_actor(user)
          raise ActiveRecord::RecordNotFound unless user
          user.with_lock do
            raise ActiveRecord::RecordNotFound unless user.active? && !user.guest?
            family = user.family
            family.with_lock { yield family }
          end
        end

        def locked_pair!(user, family, original_id, refund_id)
          raise ActiveRecord::RecordNotFound if original_id.nil? || refund_id.nil?
          allowed = family.accounts.writable_by(user).select(:id)
          found = Entry.where(account_id: allowed, id: [ original_id, refund_id ]).to_a
          raise ActiveRecord::RecordNotFound unless found.size == 2
          accounts = family.accounts.where(id: found.map(&:account_id).uniq).order(:id).lock.to_a
          raise ActiveRecord::RecordNotFound unless accounts.size == found.map(&:account_id).uniq.size &&
            accounts.all? { |account| AccountPolicy.new(user, account).permits?(:write) }
          rows = Entry.where(account_id: accounts.map(&:id), id: [ original_id, refund_id ]).order(:id).lock.index_by(&:id)
          raise ActiveRecord::RecordNotFound unless rows.size == 2
          original, refund = rows.fetch(original_id), rows.fetch(refund_id)
          Transaction.where(id: rows.values.select(&:transaction?).map(&:entryable_id)).order(:id).lock.load
          [ original, refund ]
        end

        def validate_pair!(original, refund)
          unless [ original, refund ].all? { |entry| entry.transaction? && entry.transaction.kind == "standard" &&
              !entry.transaction.pending? && !entry.excluded? && !entry.split_parent? && entry.date <= Date.current } &&
              original.amount.positive? && refund.amount.negative? && refund.date >= original.date &&
              original.account.family_id == refund.account.family_id
            raise ArgumentError, "Expected a confirmed purchase and later reverse movement"
          end
        end

        def validate_conversion!(original, refund, applied, refunded, snapshot)
          if original.currency == refund.currency
            raise ArgumentError, "Same-currency amounts must match" unless applied == refunded && snapshot.nil?
          elsif !snapshot || snapshot.family_id != original.account.family_id ||
              snapshot.from_currency != refund.currency || snapshot.to_currency != original.currency ||
              snapshot.as_of != refund.date || snapshot.convert(refunded).round(4) != applied
            raise ArgumentError, "Cross-currency refund requires its historical rate snapshot"
          end
        end
    end

    private
      def valid_initial_link
        unless original_entry && refund_entry && original_entry.account.family_id == family_id &&
            refund_entry.account.family_id == family_id && original_entry.id == original_entry_key &&
            refund_entry.id == refund_entry_key && actor&.family_id == family_id &&
            original_entry.date == original_date && refund_entry.date == refund_date &&
            original_entry.currency == currency && refund_entry.currency == refund_currency
          errors.add(:base, "Invalid refund provenance")
          return
        end
        self.class.send(:validate_pair!, original_entry, refund_entry)
        self.class.send(:validate_conversion!, original_entry, refund_entry, applied_amount, refund_amount, rate_snapshot)
      rescue ArgumentError
        errors.add(:base, "Invalid refund movement or conversion")
      end
  end
end
