module Abroa
  # Opt-in is deliberately off by default. A user's preferences are family
  # scoped and read again by every delivery job.
  class NotificationPreference < ApplicationRecord
    self.table_name = "abroa_notification_preferences"
    Conflict = Class.new(StandardError)
    FIELDS = %i[email_enabled in_app_enabled timezone quiet_start_hour quiet_end_hour].freeze

    belongs_to :user
    belongs_to :family
    validates :email_enabled, :in_app_enabled, inclusion: { in: [ true, false ] }
    validates :timezone, presence: true
    validate :valid_scope_and_hours

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      create_or_find_by!(user_id: user.id) do |pref|
        pref.family = user.family
        pref.email_enabled = false
        pref.in_app_enabled = true
        pref.timezone = Profile.for_user(user).timezone.presence || "UTC"
      end
    end

    def update_for!(actor, attributes:, version:)
      attrs = attributes.to_h.symbolize_keys
      raise ArgumentError, "Unknown notification preference" unless (attrs.keys - FIELDS).empty?
      with_lock do
        raise ActiveRecord::RecordNotFound unless actor&.active? && actor.id == user_id &&
          actor.family_id == family_id
        raise Conflict, "Preferences changed" unless version.is_a?(Integer) && version == lock_version
        update!(attrs)
        PlanningAuditEvent.record!(actor: actor, event_type: "notification_preferences.updated",
          resource: self, safe_data: { email_enabled: email_enabled, in_app_enabled: in_app_enabled })
        self
      end
    end

    def quiet_now?(now = Time.current)
      return false if quiet_start_hour.nil? || quiet_end_hour.nil?
      local = now.in_time_zone(timezone)
      hour = local.hour
      if quiet_start_hour < quiet_end_hour
        hour >= quiet_start_hour && hour < quiet_end_hour
      elsif quiet_start_hour > quiet_end_hour
        hour >= quiet_start_hour || hour < quiet_end_hour
      else
        false
      end
    end

    def payload
      { email_enabled: email_enabled, in_app_enabled: in_app_enabled,
        timezone: timezone, quiet_start_hour: quiet_start_hour,
        quiet_end_hour: quiet_end_hour, lock_version: lock_version }
    end

    private
      def valid_scope_and_hours
        errors.add(:family, :invalid) unless user && family_id == user.family_id
        errors.add(:timezone, :invalid) unless ActiveSupport::TimeZone[timezone]
        if quiet_start_hour.nil? != quiet_end_hour.nil? ||
            [ quiet_start_hour, quiet_end_hour ].compact.any? { |h| !h.is_a?(Integer) || !h.between?(0, 23) }
          errors.add(:base, "Quiet hours must specify two hours 0..23")
        end
      end
  end
end
