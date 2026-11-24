# P1.4 personal statement format coverage

The CSV parser targets the common personal-reconciliation header layouts for Alipay and WeChat Pay, using synthetic fixtures only. Header references: https://github.com/TNT-Likely/BeeCount/wiki/微信账单导入 ; https://github.com/TNT-Likely/BeeCount/wiki/支付宝账单导入 ; https://github.com/LuoDi-Nate/financial-management/blob/master/prd/v1.21.md . These are format references, not a claim of live validation or verified samples from the user's bank.

- UTF-8, UTF-8 BOM, GB18030/GBK and BOM-marked UTF-16; explicit delimiter; bounded rows/columns/files.
- Scan the leading metadata for the required personal statement header. Unknown headers are rejected; unsupported statuses or malformed rows are reported with row numbers.
- Stable source IDs and original file SHA-256 plus logical row identity. No account number, counterparty account or raw remark is copied to normalized evidence.
- Alipay/WeChat is a payment channel. Funding classification is wallet/bank_account/unknown, not an invented bank account. Transfer and refunded-order summaries are not automatically posted.
- Generic CSV uses explicit column mapping, date format, sign convention and currency. No formula evaluation or inferred dates/currencies.
- XLSX extraction and reuse of Sure PDF extraction are next implementation steps. No unsupported bank-specific templates are claimed.
