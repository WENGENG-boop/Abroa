class Abroa::OperationalConfig < ApplicationRecord
  self.table_name = "abroa_operational_configs"

  CATEGORIES = %w[bank_provider ai_model import_template region language currency channel policy].freeze
  FIELDS = {
    "bank_provider" => %w[enabled display_name regions status capabilities],
    "ai_model" => %w[enabled display_name regions status],
    "import_template" => %w[enabled display_name version file_format status],
    "region" => %w[enabled languages currencies],
    "language" => %w[enabled display_name],
    "currency" => %w[enabled precision],
    "channel" => %w[enabled region],
    "policy" => %w[enabled duration_days]
  }.freeze
  STATUSES = %w[available degraded unavailable disabled].freeze
  FILE_FORMATS = %w[csv xlsx pdf ofx qif].freeze
  CAPABILITIES = %w[sync balances transactions coverage webhook].freeze

  validates :category, inclusion: { in: CATEGORIES }
  validates :code, presence: true, uniqueness: { scope: :category },
    format: { with: /\A[A-Za-z0-9][A-Za-z0-9_-]{1,63}\z/ }
  validate :validate_settings_whitelist

  def payload
    { id: id, category: category, code: code, settings: settings,
      version: lock_version, updated_at: updated_at, created_at: created_at }
  end

  private

    def validate_settings_whitelist
      unless settings.is_a?(Hash) && settings.keys.all? { |k| k.is_a?(String) } &&
          (settings.keys - FIELDS.fetch(category, [])).empty? &&
          settings.to_json.bytesize <= 2_048
        errors.add(:settings, "contains unsupported or oversized fields")
        return
      end

      settings.each do |key, value|
        valid = case key
        when "enabled"
          value == true || value == false
        when "display_name"
          value.is_a?(String) && value.bytesize.between?(1, 80) &&
            value.match?(/\A[\p{L}\p{N}\s._+\-()]+\z/u) &&
            !value.match?(/\A(?:sk-|ghp_|github_pat_|Bearer\s|token-|secret-)/i)
        when "regions", "languages", "currencies"
          value.is_a?(Array) && value.size.between?(0, 35) && value.uniq == value &&
            value.all? do |code|
              code.is_a?(String) && code.match?(
                key == "languages" ? /\A[a-z]{2,3}(?:-[A-Z]{2})?\z/ :
                key == "currencies" ? /\A[A-Z]{3}\z/ : /\A[A-Z]{2}\z/
              )
            end
        when "capabilities"
          value.is_a?(Array) && value.size <= CAPABILITIES.size &&
            value.uniq == value && (value - CAPABILITIES).empty?
        when "status"
          STATUSES.include?(value)
        when "version"
          value.is_a?(String) && value.match?(/\A[0-9]{1,4}\.[0-9]{1,4}(?:\.[0-9]{1,4})?\z/)
        when "file_format"
          FILE_FORMATS.include?(value)
        when "region"
          value.is_a?(String) && value.match?(/\A[A-Z]{2}\z/)
        when "precision"
          value.is_a?(Integer) && value.between?(0, 6)
        when "duration_days"
          value.is_a?(Integer) && value.between?(1, 3650)
        else
          false
        end
        errors.add(:settings, "invalid allowed value for #{key}") unless valid
      end
    end
end
