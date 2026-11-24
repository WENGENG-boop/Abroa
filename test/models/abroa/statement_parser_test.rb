require "test_helper"
require "stringio"

class Abroa::StatementParserTest < ActiveSupport::TestCase
  test "Alipay personal CSV recognizes header after preamble and handles UTF8 BOM and GB18030" do
    text = <<~CSV
      支付宝交易记录明细
      本文件为合成测试数据
      交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注
      2025-01-10 10:00:00,餐饮,测试商户,,午餐,支出,100.00,余额,交易成功,order-1,merchant-1,
      2025-01-11 10:00:00,购物,测试商户,,书籍,支出,30.00,银行卡,交易关闭,order-2,merchant-2,
      2025-01-12 10:00:00,退款,测试商户,,退款,收入,20.00,银行卡,退款成功,refund-1,merchant-1,
    CSV
    [ "\uFEFF" + text, text.encode("GB18030") ].each do |bytes|
      result = Abroa::StatementParser.parse_csv(bytes: bytes.b, source_kind: "alipay_statement", source_instance_key: "wallet-1")
      assert_empty result.issues
      assert_equal 3, result.records.size
      purchase, closed, refund = result.records
      assert_equal "CNY", purchase.currency
      assert_equal "wallet", purchase.funding_kind
      assert_equal "alipay", purchase.payment_channel
      assert_equal BigDecimal("100"), purchase.amount
      assert_equal "merchant-1", purchase.reference
      assert_equal "closed", closed.provider_status
      assert_equal "bank_account", refund.funding_kind
      assert_equal "refund", refund.transaction_kind
      assert_equal BigDecimal("-20"), refund.signed_amount
      assert_equal "order-1", purchase.external_id
    end
  end

  test "WeChat payment channel is not an inferred bank account" do
    text = <<~CSV
      微信支付账单明细
      交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
      2025-01-10 10:00:00,商户消费,测试商户,测试商品,支出,￥88.50,招商银行储蓄卡(1234),支付成功,wx-1,m-1,
      2025-01-11 10:00:00,转账,测试对方,转账,不计收支,￥50,零钱,支付成功,wx-2,m-2,
    CSV
    result = Abroa::StatementParser.parse_csv(bytes: text.b, source_kind: "wechat_statement", source_instance_key: "wx-1")
    assert_empty result.issues
    assert_equal "wechat", result.records[0].payment_channel
    assert_equal "bank_account", result.records[0].funding_kind
    assert_equal "unknown", result.records[1].direction
    assert_equal "transfer", result.records[1].transaction_kind
  end

  test "generic CSV requires explicit mapping and preserves distinct identical rows" do
    text = "Date,Amount,Description\n2025-01-10,-12.50,Cafe\n2025-01-10,-12.50,Cafe\n"
    mapping = { date: "Date", amount: "Amount", description: "Description", date_format: "%Y-%m-%d", signage: "inflows_positive" }
    result = Abroa::StatementParser.parse_csv(bytes: text.b, source_kind: "generic_csv",
      source_instance_key: "checking", mapping: mapping, default_currency: "GBP")
    assert_empty result.issues
    assert_equal 2, result.records.size
    assert_equal "outflow", result.records.first.direction
    assert_equal BigDecimal("12.50"), result.records.first.amount
    assert_not_equal result.records[0].source_row_key, result.records[1].source_row_key
  end

  test "invalid rows and formula-like fields are reported without ledger writes" do
    text = "Date,Amount,Description\n2025-01-10,NaN,Cafe\n2025-01-10,12,=1+1\n2025-01-10,-12,Valid\n"
    mapping = { date: "Date", amount: "Amount", description: "Description", date_format: "%Y-%m-%d", signage: "inflows_positive" }
    assert_no_difference "Entry.count" do
      result = Abroa::StatementParser.parse_csv(bytes: text.b, source_kind: "generic_csv",
        source_instance_key: "checking", mapping: mapping, default_currency: "GBP")
      assert_equal 2, result.issues.size
      assert_equal 1, result.records.size
      assert_equal [ 2, 3 ], result.issues.map(&:row_number)
    end
  end

  test "unsupported header cannot become a silently successful empty import" do
    assert_raises(Abroa::StatementParser::UnsupportedFormat) do
      Abroa::StatementParser.parse_csv(bytes: "nonsense\n".b, source_kind: "wechat_statement", source_instance_key: "wx")
    end
  end
end
