require "csv"

module Abroa
  class StatementParser
    UnsupportedFormat = Class.new(StandardError)
    InvalidRow = Class.new(StandardError)
    Issue = Data.define(:row_number, :code, :message)
    Result = Data.define(:file_sha256, :records, :issues)

    MAX_BYTES = 10 * 1024 * 1024
    MAX_ROWS = 10_000
    MAX_COLUMNS = 128
    MAX_FIELD = 8192
    PERSONAL_KINDS = %w[alipay_statement wechat_statement].freeze
    GENERIC_KINDS = %w[bank_statement generic_csv generic_xlsx generic_pdf].freeze
    DATE_FORMATS = %w[%Y-%m-%d %Y/%m/%d %d/%m/%Y %m/%d/%Y %d.%m.%Y].freeze
    FORMULA = /\A[=+@-]/

    COMMON_HEADERS = {
      date: [ "交易时间", "付款时间", "交易创建时间" ],
      classification: [ "交易分类", "交易类型", "类型" ],
      description: [ "商品说明", "商品名称", "商品" ],
      counterparty: [ "交易对方" ],
      direction: [ "收/支", "收支" ],
      amount: [ "金额", "金额(元)", "金额（元）" ],
      payment_method: [ "收/付款方式", "支付方式", "付款方式" ],
      status: [ "交易状态", "当前状态" ],
      currency: [ "币种", "货币种类" ]
    }.freeze
    PERSONAL_IDS = {
      "alipay_statement" => { external_id: [ "交易订单号", "交易号" ], reference: [ "商家订单号" ] },
      "wechat_statement" => { external_id: [ "交易单号" ], reference: [ "商户单号" ] }
    }.freeze
    STATUS_MAP = {
      "交易成功" => "posted", "支付成功" => "posted", "已支付" => "posted",
      "已到账" => "posted", "对方已收钱" => "posted", "已收钱" => "posted", "退款成功" => "posted",
      "交易关闭" => "closed", "已关闭" => "closed", "已取消" => "closed",
      "支付失败" => "failed", "交易失败" => "failed", "退款失败" => "failed",
      "等待付款" => "pending", "待支付" => "pending", "交易进行中" => "pending",
      "支付中" => "pending", "退款中" => "pending", "处理中" => "pending",
      "已全额退款" => "pending", "已部分退款" => "pending", "已退款" => "pending"
    }.freeze

    def self.parse_csv(bytes:, source_kind:, source_instance_key:, mapping: nil, default_currency: nil, separator: ",")
      unless bytes.is_a?(String) && bytes.bytesize.between?(1, MAX_BYTES) && [ ",", ";", "\t" ].include?(separator)
        raise UnsupportedFormat, "Unsupported CSV size or separator"
      end
      text = decode(bytes)
      rows = CSV.parse(text, col_sep: separator)
      parse_table(rows: rows, file_sha256: Digest::SHA256.hexdigest(bytes),
        source_kind: source_kind, source_instance_key: source_instance_key,
        mapping: mapping, default_currency: default_currency)
    rescue CSV::MalformedCSVError, EncodingError
      raise UnsupportedFormat, "CSV is malformed or has unsupported encoding"
    end

    def self.parse_table(rows:, file_sha256:, source_kind:, source_instance_key:, mapping: nil, default_currency: nil)
      unless rows.is_a?(Array) && rows.size <= MAX_ROWS + 100 &&
          rows.all? { |row| row.is_a?(Array) && row.size <= MAX_COLUMNS }
        raise UnsupportedFormat, "Statement exceeds row or column limits"
      end
      unless (PERSONAL_KINDS + GENERIC_KINDS).include?(source_kind)
        raise UnsupportedFormat, "Unsupported statement type"
      end
      NormalizedSource.file_row_key(file_sha256, 1)
      personal = PERSONAL_KINDS.include?(source_kind)
      mapping = personal ? nil : generic_mapping!(mapping, default_currency)
      header, header_index = find_header!(rows, source_kind, mapping)
      records, issues = [], []
      rows.drop(header_index + 1).each_with_index do |row, index|
        number = header_index + index + 2
        next if row.all? { |cell| cell.nil? || (cell.is_a?(String) && cell.blank?) }
        break if personal && footer?(row)
        if records.size + issues.size >= MAX_ROWS
          raise UnsupportedFormat, "Statement exceeds row limit"
        end
        begin
          if row.any? { |cell| cell.is_a?(String) && cell.bytesize > MAX_FIELD }
            raise InvalidRow, "Field too long"
          end
          values = header.transform_values { |column| row[column] }
          normalized = personal ? personal_values(values, source_kind) : generic_values(values, mapping, default_currency)
          records << NormalizedSource.build(
            **normalized, source_kind: source_kind, source_instance_key: source_instance_key,
            source_row_key: NormalizedSource.file_row_key(file_sha256, number),
            raw_digest: Digest::SHA256.hexdigest(JSON.generate(row))
          )
        rescue ArgumentError, Date::Error, InvalidRow
          issues << Issue.new(row_number: number, code: "invalid_row", message: "Invalid or unsupported statement field")
        end
      end
      Result.new(file_sha256: file_sha256, records: records.freeze, issues: issues.freeze)
    end

    class << self
      private
        def decode(bytes)
          raw = bytes.b
          text = if raw.start_with?("\xEF\xBB\xBF".b)
            raw.byteslice(3..).force_encoding(Encoding::UTF_8)
          elsif raw.start_with?("\xFF\xFE".b)
            raw.byteslice(2..).force_encoding("UTF-16LE").encode("UTF-8")
          elsif raw.start_with?("\xFE\xFF".b)
            raw.byteslice(2..).force_encoding("UTF-16BE").encode("UTF-8")
          else
            candidate = raw.dup.force_encoding(Encoding::UTF_8)
            candidate.valid_encoding? ? candidate : raw.force_encoding("GB18030").encode("UTF-8")
          end
          raise UnsupportedFormat, "Invalid text encoding" unless text.valid_encoding? && !text.include?("\0")
          text
        end

        def generic_mapping!(mapping, default_currency)
          raise UnsupportedFormat, "Explicit column mapping required" unless mapping.is_a?(Hash)
          mapping = mapping.symbolize_keys
          required = %i[date amount description date_format signage]
          allowed = required + %i[currency direction status external_id reference transaction_kind]
          unless (required - mapping.keys).empty? && (mapping.keys - allowed).empty? &&
              mapping.values.all? { |value| value.is_a?(String) && value.present? && value.length <= 128 } &&
              DATE_FORMATS.include?(mapping[:date_format]) &&
              %w[inflows_positive inflows_negative direction_column].include?(mapping[:signage])
            raise UnsupportedFormat, "Invalid generic mapping"
          end
          if mapping[:signage] == "direction_column" && mapping[:direction].nil?
            raise UnsupportedFormat, "Direction column required"
          end
          if mapping[:currency].nil?
            Decimal.currency!(default_currency)
          end
          mapping
        rescue ArgumentError
          raise UnsupportedFormat, "Explicit valid currency required"
        end

        def find_header!(rows, source_kind, mapping)
          if PERSONAL_KINDS.include?(source_kind)
            aliases = COMMON_HEADERS.merge(PERSONAL_IDS.fetch(source_kind))
            required = %i[date direction amount status external_id]
          else
            aliases = mapping.except(:date_format, :signage).transform_values { |value| [ value ] }
            required = aliases.keys
          end
          rows.first(100).each_with_index do |row, index|
            labels = row.map { |cell| cell.is_a?(String) ? cell.strip : "" }
            next unless required.all? { |key| (aliases.fetch(key) & labels).any? }

            result = aliases.each_with_object({}) do |(key, names), columns|
              matches = names.flat_map { |name| labels.each_index.select { |position| labels[position] == name } }
              raise UnsupportedFormat, "Ambiguous statement column" if matches.size > 1
              columns[key] = matches.first if matches.one?
            end
            raise UnsupportedFormat, "A column cannot represent multiple fields" unless result.values.uniq.size == result.size
            return [ result, index ]
          end
          raise UnsupportedFormat, "Required statement header not found"
        end

        def personal_values(row, source_kind)
          direction = direction_value(row[:direction])
          status = STATUS_MAP.fetch(clean(row[:status])) { raise InvalidRow, "Unknown transaction status" }
          classification = clean(row[:classification]).to_s
          kind = if clean(row[:status]).in?(%w[已全额退款 已部分退款 已退款])
            "unknown"
          elsif classification.include?("退款") || clean(row[:status]) == "退款成功"
            direction == "inflow" ? "refund" : "unknown"
          elsif direction == "unknown" || classification.match?(/转账|提现|充值|还款|余额宝|零钱通/)
            "transfer"
          else
            direction == "outflow" ? "payment" : "income"
          end
          date, time = personal_date(row[:date])
          description = [ clean(row[:counterparty]), clean(row[:description]) ].compact.uniq.join(" · ").presence ||
            classification.presence || "Imported transaction"
          method = clean(row[:payment_method]).to_s
          channel = source_kind == "alipay_statement" ? "alipay" : "wechat"
          {
            external_id: clean(row[:external_id]), reference: clean(row[:reference]), local_date: date,
            occurred_at: time, amount: amount_value(row[:amount], signed: false),
            currency: normalize_currency(row[:currency] || "CNY"),
            direction: direction, provider_status: status, transaction_kind: kind,
            description: description.truncate(256), payment_channel: channel, funding_kind: funding_kind(method, channel)
          }
        end

        def generic_values(row, mapping, default_currency)
          amount = amount_value(row[:amount], signed: mapping[:signage] != "direction_column")
          direction = case mapping[:signage]
          when "direction_column" then direction_value(row[:direction])
          when "inflows_positive" then amount.negative? ? "outflow" : "inflow"
          when "inflows_negative" then amount.negative? ? "inflow" : "outflow"
          end
          raw_date = clean(row[:date])
          date = Date.strptime(raw_date.to_s, mapping[:date_format])
          raise InvalidRow, "Invalid date" unless date.strftime(mapping[:date_format]) == raw_date
          status = mapping[:status] ? clean(row[:status]) : "posted"
          kind = mapping[:transaction_kind] ? clean(row[:transaction_kind]) : (direction == "outflow" ? "payment" : "income")
          {
            external_id: clean(row[:external_id]), reference: clean(row[:reference]), local_date: date,
            amount: amount.abs, currency: normalize_currency(row[:currency] || default_currency),
            direction: direction, provider_status: status, transaction_kind: kind,
            description: (clean(row[:description]) || "Imported transaction").truncate(256),
            funding_kind: "unknown"
          }
        end

        def direction_value(value)
          case clean(value)
          when "收入", "inflow" then "inflow"
          when "支出", "outflow" then "outflow"
          when "不计收支", "不计入收支", "unknown" then "unknown"
          else raise InvalidRow, "Unknown direction"
          end
        end

        def funding_kind(value, channel)
          return "unknown" if value.match?(/[+＋、与]/)
          wallets = channel == "alipay" ? %w[余额 支付宝余额] : %w[零钱 微信零钱]
          return "wallet" if wallets.include?(value)
          return "bank_account" if value.match?(/银行卡|储蓄卡|信用卡/)
          "unknown"
        end

        def personal_date(value)
          text = clean(value)
          match = text.to_s.match(/\A(\d{4})[-\/](\d{2})[-\/](\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2}))?\z/)
          raise InvalidRow, "Invalid transaction date" unless match
          year, month, day = match.captures.first(3).map(&:to_i)
          date = Date.new(year, month, day)
          return [ date, nil ] unless match[4]
          hour, minute, second = match.captures.drop(3).map(&:to_i)
          raise InvalidRow, "Invalid time" unless hour.between?(0, 23) && minute.between?(0, 59) && second.between?(0, 59)
          [ date, Time.new(year, month, day, hour, minute, second, "+08:00") ]
        end

        def amount_value(value, signed:)
          text = value.to_s.strip.sub(/\A[¥￥]\s*/, "")
          if text.include?(",")
            raise InvalidRow, "Invalid grouped amount" unless text.match?(/\A[+-]?\d{1,3}(?:,\d{3})+(?:\.\d+)?\z/)
            text = text.delete(",")
          end
          Decimal.money!(text, nonnegative: !signed)
        end

        def normalize_currency(value)
          code = clean(value)
          code = "CNY" if %w[人民币 RMB].include?(code)
          Decimal.currency!(code)
        end

        def clean(value)
          return nil if value.nil?
          raise InvalidRow, "Unsupported cell value" unless value.is_a?(String)
          text = value.strip
          return nil if text.blank? || text == "/"
          raise InvalidRow, "Formula-like text" if FORMULA.match?(text)
          text
        end

        def footer?(row)
          first = row.first.to_s.strip
          first.match?(/\A[-—=]{5,}\z/) ||
            (row.drop(1).all?(&:blank?) && first.match?(/\A(?:共\d+笔|合计|收入：|支出：)/))
        end
    end
  end
end
