module Abroa
  class Profile < ApplicationRecord
    self.table_name = "abroa_profiles"

    Conflict = Class.new(StandardError)
    InvalidInput = Class.new(StandardError)

    MODES = %w[simple professional custom].freeze
    STEPS = %w[role region preferences review complete].freeze
    PREFERENCE_FIELDS = %i[student_enabled parent_enabled origin_country residence_country display_currency timezone mode].freeze

    belongs_to :user
    validates :user_id, uniqueness: true
    validates :student_enabled, :parent_enabled, inclusion: { in: [ true, false ] }
    validates :mode, inclusion: { in: MODES }
    validates :onboarding_step, inclusion: { in: STEPS }
    validates :origin_country, :residence_country, length: { is: 2 }, allow_nil: true
    validates :timezone, length: { maximum: 128 }, allow_nil: true
    validate :known_codes
    validate :valid_completion

    before_validation :normalize_codes

    class << self
      def for_user(user)
        find_by(user: user) || new(user: user)
      end

      def change_for!(user, version:, attributes:)
        attributes = attributes.symbolize_keys
        raise InvalidInput, "Unknown profile field" unless (attributes.keys - PREFERENCE_FIELDS).empty?
        raise InvalidInput, "Expected boolean role flags" unless attributes.slice(:student_enabled, :parent_enabled).values.all? { |value| value == true || value == false }
        raise InvalidInput, "Expected string or null preference" unless attributes.except(:student_enabled, :parent_enabled).values.all? { |value| value.nil? || value.is_a?(String) }

        update_for!(user, version:) { |profile| profile.assign_attributes(attributes) }
      end

      def advance_for!(user, version:, step:)
        raise InvalidInput, "Unknown onboarding step" unless STEPS[0...-1].include?(step)

        update_for!(user, version:) do |profile|
          raise Conflict, "Onboarding is already complete" if profile.completed_at?
          if step != "role" && !profile.role_selected?
            profile.errors.add(:onboarding_step, "requires a selected role")
            raise ActiveRecord::RecordInvalid.new(profile)
          end
          profile.onboarding_step = step
        end
      end

      def complete_for!(user, version:, key:)
        validate_version!(version)
        unless key.is_a?(String) && key.present? && key.bytesize <= 128
          raise InvalidInput, "Idempotency-Key must contain 1 to 128 bytes"
        end
        digest = Digest::SHA256.hexdigest(key)

        user.with_lock do
          profile = for_user(user)
          if profile.completed_at?
            unless profile.completion_key_digest == digest && profile.completion_request_version == version
              raise Conflict, "Onboarding has already been completed"
            end
            next profile
          end

          check_version!(profile, version)
          profile.assign_attributes(
            onboarding_step: "complete", completed_at: Time.current,
            completion_key_digest: digest, completion_request_version: version,
            completion_version: version + 1
          )
          persist!(profile)
        end
      end

      private
        def update_for!(user, version:)
          validate_version!(version)
          # Serializes first creation as well as updates; a missing profile has no row to lock.
          user.with_lock do
            profile = for_user(user)
            check_version!(profile, version)
            yield profile
            persist!(profile)
          end
        end

        def validate_version!(version)
          unless version.is_a?(Integer) && version.between?(0, 2_147_483_646)
            raise InvalidInput, "lock_version must be a non-negative integer"
          end
        end

        def check_version!(profile, version)
          raise Conflict, "Profile version has changed" unless profile.lock_version == version
        end

        def persist!(profile)
          profile.lock_version = 1 if profile.new_record?
          profile.save!
          profile
        end
    end

    def role_selected?
      student_enabled? || parent_enabled?
    end

    def preferences_payload
      attributes.slice(*PREFERENCE_FIELDS.map(&:to_s), "lock_version")
    end

    def onboarding_payload(replay: false)
      {
        step: onboarding_step,
        completed_at: completed_at&.iso8601(6),
        lock_version: replay ? completion_version : lock_version
      }
    end

    private
      def normalize_codes
        self.origin_country = origin_country&.strip&.upcase.presence
        self.residence_country = residence_country&.strip&.upcase.presence
        self.display_currency = display_currency&.strip&.upcase.presence
        self.timezone = timezone&.strip.presence
      end

      def known_codes
        %i[origin_country residence_country].each do |field|
          code = public_send(field)
          errors.add(field, :invalid) if code.present? && ISO3166::Country.new(code).nil?
        end
        if display_currency.present?
          normalized = Family.normalize_currency_code(display_currency)
          normalized ? self.display_currency = normalized : errors.add(:display_currency, :invalid)
        end
        errors.add(:timezone, :invalid) if timezone.present? && ActiveSupport::TimeZone[timezone].blank?
      end

      def valid_completion
        return unless onboarding_step == "complete"
        errors.add(:onboarding_step, "requires a selected role") unless role_selected?
        errors.add(:completed_at, :blank) unless completed_at?
      end
  end
end
