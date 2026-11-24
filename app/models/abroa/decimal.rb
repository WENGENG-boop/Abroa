module Abroa
  module Decimal
    MAX_MONEY = BigDecimal("1000000000000000")
    MAX_RATE = BigDecimal("100000000000000")

    module_function

    def parse!(value)
      unless value.is_a?(BigDecimal) || value.is_a?(Integer) ||
          (value.is_a?(String) && value.bytesize <= 128 && value.match?(/\A[+-]?\d+(?:\.\d+)?\z/))
        raise ArgumentError, "Expected a finite decimal string"
      end
      result = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
      raise ArgumentError, "Expected a finite decimal" unless result.finite?
      result
    end

    def money!(value, positive: false, nonnegative: false)
      number = parse!(value)
      if number.abs >= MAX_MONEY || number != number.round(4) ||
          (positive && !number.positive?) || (nonnegative && number.negative?)
        raise ArgumentError, "Amount is outside the permitted range or precision"
      end
      number
    end

    def rate!(value)
      rounded = parse!(value).round(16)
      raise ArgumentError, "Rate outside permitted precision" unless rounded.positive? && rounded < MAX_RATE
      rounded
    end

    def currency!(value)
      code = value.is_a?(String) && Family.normalize_currency_code(value)
      raise ArgumentError, "Unsupported currency" unless code
      code
    end
  end
end
