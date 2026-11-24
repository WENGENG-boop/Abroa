module Abroa
  class RateSnapshot < ApplicationRecord
    self.table_name = "abroa_rate_snapshots"
    MissingRate = Class.new(StandardError)
    DEFAULT_LOOKBACK_DAYS = 5

    belongs_to :family
    validates :from_currency, :to_currency, :rate, :rate_date, :as_of, :source, :quality, presence: true
    validates :quality, inclusion: { in: %w[exact historical_fallback parity] }
    validate :valid_snapshot

    Quote = Data.define(:from_currency, :to_currency, :rate, :rate_date, :as_of, :source, :source_reference, :quality) do
      def missing?
        rate.nil?
      end

      def convert(amount, display: false)
        number = Decimal.parse!(amount)
        return nil if missing?
        result = number * rate
        display ? result.round(Money::Currency.new(to_currency).default_precision) : result
      end

      def capture!(family:)
        raise MissingRate, "No historical exchange rate available" if missing?
        RateSnapshot.create!(family: family, **to_h)
      end

      def payload
        {
          from_currency: from_currency, to_currency: to_currency,
          rate: rate&.to_s("F"), rate_date: rate_date&.iso8601, as_of: as_of.iso8601,
          source: source, quality: quality, incomplete: missing?
        }
      end
    end

    def self.quote(from:, to:, date:, lookback_days: DEFAULT_LOOKBACK_DAYS)
      from, to = Decimal.currency!(from), Decimal.currency!(to)
      unless date.instance_of?(Date) && date <= Date.current && date.year.positive? &&
          lookback_days.is_a?(Integer) && lookback_days.between?(0, 365)
        raise ArgumentError, "Invalid historical date or rate lookback"
      end
      if from == to
        return Quote.new(from_currency: from, to_currency: to, rate: BigDecimal("1"),
          rate_date: date, as_of: date, source: "same_currency", source_reference: nil, quality: "parity")
      end
      stored = ExchangeRate.where(from_currency: from, to_currency: to, date: (date - lookback_days)..date)
        .where("rate > 0").order(date: :desc).first
      if stored
        begin
          rate = Decimal.rate!(stored.rate)
          return Quote.new(from_currency: from, to_currency: to, rate: rate,
            rate_date: stored.date, as_of: date, source: "sure_exchange_rate",
            source_reference: stored.id, quality: stored.date == date ? "exact" : "historical_fallback")
        rescue ArgumentError
          # A rate outside storage precision cannot be used as parity or zero.
        end
      end
      Quote.new(from_currency: from, to_currency: to, rate: nil, rate_date: nil,
        as_of: date, source: nil, source_reference: nil, quality: "missing")
    end

    def convert(amount, display: false)
      result = Decimal.parse!(amount) * rate
      display ? result.round(Money::Currency.new(to_currency).default_precision) : result
    end

    def readonly?
      persisted? || super
    end

    private
      def valid_snapshot
        begin
          errors.add(:from_currency, :invalid) unless Decimal.currency!(from_currency) == from_currency
          errors.add(:to_currency, :invalid) unless Decimal.currency!(to_currency) == to_currency
          errors.add(:rate, :invalid) unless Decimal.rate!(rate) == rate
        rescue ArgumentError
          errors.add(:base, "Invalid rate or currency")
        end
        return unless rate_date && as_of
        correct = case quality
        when "parity"
          from_currency == to_currency && rate == 1 && rate_date == as_of && source == "same_currency"
        when "exact"
          from_currency != to_currency && rate_date == as_of && source_reference.present?
        when "historical_fallback"
          from_currency != to_currency && rate_date < as_of && source_reference.present?
        end
        errors.add(:quality, :invalid) unless correct
      end
  end
end
