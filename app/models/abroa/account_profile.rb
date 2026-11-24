module Abroa
  class AccountProfile < ApplicationRecord
    self.table_name = "abroa_account_profiles"
    belongs_to :family
    belongs_to :account
    validates :account_id, uniqueness: true
    validates :wallet_kind, inclusion: { in: %w[alipay wechat other] }, allow_nil: true
    validate :valid_region
    validate :same_tenant_and_wallet_type
    before_validation :normalize_region

    def self.for_user(user, account_id)
      account = user.family.accounts.accessible_by(user).find(account_id)
      find_by(account: account, family: user.family) || new(account: account, family: user.family)
    end

    def self.change_for!(user, account_id, **attributes)
      unless (attributes.keys - %i[country wallet_kind lock_version]).empty?
        raise ArgumentError, "Unknown account profile field"
      end
      user.with_lock do
        raise ActiveRecord::RecordNotFound if !user.active? || user.guest?
        account = user.family.accounts.writable_by(user).find(account_id)
        account.with_lock do
          raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, account).permits?(:write)
          profile = find_by(account: account, family: user.family) || new(account: account, family: user.family)
          if attributes.key?(:lock_version)
            expected = attributes.delete(:lock_version)
            raise ArgumentError, "Invalid lock_version" unless expected.is_a?(Integer) && expected >= 0
            raise Profile::Conflict, "Account profile changed" unless profile.lock_version == expected
          end
          unless attributes.values.all? { |value| value.nil? || value.is_a?(String) }
            raise ArgumentError, "Expected strings or null"
          end
          profile.assign_attributes(attributes)
          profile.lock_version = 1 if profile.new_record?
          profile.save!
          profile
        end
      end
    end

    def payload
      { account_id: account_id, country: country, wallet_kind: wallet_kind, lock_version: lock_version }
    end

    private
      def normalize_region
        self.country = country&.strip&.upcase.presence
        self.wallet_kind = wallet_kind.presence
      end

      def valid_region
        return if country.nil?
        errors.add(:country, :invalid) unless country.match?(/\A[A-Z]{2}\z/) && ISO3166::Country.new(country)
      end

      def same_tenant_and_wallet_type
        errors.add(:account, :invalid) unless account && account.family_id == family_id
        if wallet_kind.present? && account&.accountable_type != "Depository"
          errors.add(:wallet_kind, "requires a stored-value deposit account")
        end
      end
  end
end
