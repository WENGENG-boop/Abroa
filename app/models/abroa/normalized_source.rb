module Abroa
  class NormalizedSource
    KINDS = %w[bank_provider bank_statement alipay_statement wechat_statement generic_csv generic_xlsx generic_pdf].freeze
    DIRECTIONS = %w[inflow outflow unknown].freeze
    PROVIDER_STATUSES = %w[posted pending failed closed].freeze
    TRANSACTION_KINDS = %w[payment income refund transfer unknown].freeze
    CHANNELS = %w[alipay wechat apple_pay google_pay card cash bank_transfer other].freeze

    FIELDS = %i[source_kind source_instance_key source_row_key external_id raw_digest local_date
      occurred_at amount currency direction provider_status transaction_kind description payment_channel
      reference provider_name].freeze
    attr_reader(*FIELDS)

    def self.build(source_kind:, source_instance_key:, source_row_key:, raw_digest:, local_date:, amount:,
        currency:, direction:, provider_status:, transaction_kind:, description:, external_id: nil,
        occurred_at: nil, payment_channel: nil, reference: nil, provider_name: nil)
      values = {
        source_kind: choice!(source_kind, KINDS), source_instance_key: text!(source_instance_key, 128),
        source_row_key: text!(source_row_key, 192), external_id: optional_text!(external_id, 256),
        raw_digest: digest!(raw_digest), local_date: local_date, occurred_at: occurred_at,
        amount: Decimal.money!(amount, nonnegative: true), currency: Decimal.currency!(currency),
        direction: choice!(direction, DIRECTIONS), provider_status: choice!(provider_status, PROVIDER_STATUSES),
        transaction_kind: choice!(transaction_kind, TRANSACTION_KINDS), description: text!(description, 256),
        payment_channel: payment_channel.nil? ? nil : choice!(payment_channel, CHANNELS),
        reference: optional_text!(reference, 256), provider_name: optional_text!(provider_name, 64)
      }
      unless local_date.instance_of?(Date) && local_date.year.positive?
        raise ArgumentError, "Invalid source date"
      end
      unless occurred_at.nil? || occurred_at.is_a?(Time) || occurred_at.is_a?(ActiveSupport::TimeWithZone)
        raise ArgumentError, "Invalid source timestamp"
      end
      if values[:provider_status].in?(%w[posted pending]) &&
          (!values[:amount].positive? || direction == "unknown")
        raise ArgumentError, "A financial movement requires a positive magnitude and known direction"
      end
      if source_kind == "bank_provider" && (values[:external_id].nil? || values[:provider_name].nil?)
        raise ArgumentError, "A provider record requires provider and stable external identity"
      end

      new(values)
    end

    def self.file_row_key(file_sha256, row_number)
      digest!(file_sha256)
      unless row_number.is_a?(Integer) && row_number.positive?
        raise ArgumentError, "Invalid source row number"
      end
      "file:#{file_sha256}:#{row_number}"
    end

    def signed_amount
      case direction
      when "inflow" then -amount
      when "outflow" then amount
      else raise ArgumentError, "Unknown transaction direction"
      end
    end

    # Excludes file identity: the same external order may be observed in multiple files.
    def payload
      {
        "local_date" => local_date.iso8601, "occurred_at" => occurred_at&.iso8601(6),
        "amount" => amount.to_s("F"), "currency" => currency, "direction" => direction,
        "provider_status" => provider_status, "transaction_kind" => transaction_kind,
        "description" => description, "payment_channel" => payment_channel,
        "reference" => reference, "provider_name" => provider_name
      }
    end

    def initialize(values)
      FIELDS.each do |field|
        value = values.fetch(field)
        value = value.dup.freeze if value.is_a?(String)
        instance_variable_set(:"@#{field}", value)
      end
      freeze
    end
    private_class_method :new

    class << self
      private
        def text!(value, limit)
          unless value.is_a?(String) && value.present? && value.valid_encoding? &&
              value.length <= limit && !value.include?("\0")
            raise ArgumentError, "Invalid source text"
          end
          value
        end

        def optional_text!(value, limit)
          value.nil? ? nil : text!(value, limit)
        end

        def choice!(value, options)
          raise ArgumentError, "Unknown source field" unless options.include?(value)
          value
        end

        def digest!(value)
          unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
            raise ArgumentError, "Invalid SHA-256 digest"
          end
          value
        end
    end
  end
end
