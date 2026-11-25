# Abroa P4 后端补缺、修复及最新代码联合验收（2026-11-25）

> 状态：**P4 BACKEND VERIFIED — SCOPE LIMITED（正式签收）**。下列证据均基于本轮业务 SHA `aae713857` 的实际隔离测试，非借用之前 SHA 的成功结果。正式签收仅覆盖 P4.1–P4.5 后端和 P1–P4 联合范围。

业务代码已验收冻结 SHA：`aae713857`，分支 `abroa/development`。在原始 P4.1–P4.5（A10–A14）和已签收 `0f0d101dc` 基础上新增两项真实缺陷修复；原冻结项目、生产银行和 P2/P3 源数据库未修改。

## 发现的缺陷、修复及红绿测试

1. 上游 Chat Completions 返回有效 JSON 但结构错误（例如 `null`、数字、字符串、`choices` 非数组、`message` 非对象、`usage` 非对象）时，旧网关抛 `NoMethodError` 或其它非业务异常；HTTP framing 和传输中断也可能漏网。新增预期 `ModelFailure` 的失败测试，修复 `app/models/abroa/ai_model_gateway.rb` 对协议结构和可预期网络故障的安全映射，禁止带工具调用完成原因冒充普通只读答案。先 10 runs / 27 assertions / **2 failures**，修后 10/38、0 failures/errors。提交 `9fcc46bc1`。
2. P4 AI 财务问答没有获取 A11 确定性预测，也没有个人现金流汇总；学生获取项目报告但不含预测。家长问答缺独立 forecasts_read/account_balance/fees_read 权限及项目跨月限制，可能无法回答合理问题。补充个人及项目报告+保守预测，家长预测必须实时拥有四项 Grant；无完整项目自然月时明确返回 incomplete，不触发未经授权的小窗口查询。交易分类仅携带指定 Entry 的必要上下文，不附带完整报告或预测。先 33 runs / 174 assertions / **2 errors**；后在新增家长授权复验基础上通过。提交 `aae713857`。

修复后联合定向专项：**47 tests / 321 assertions / 0 failures / 0 errors / 0 skips / exit 0**。日志 `D:\开发\Abroa\.p4-env\logs\fix-20261125T125224Z-320028.log`；新增改动 RuboCop 4 files / 0 offenses / exit 0，日志 `D:\开发\Abroa\.p4-env\logs\fix-20261125T125238Z-320839.log`。含 A14 本地真实 TCP/HTTP、实际 PostgreSQL 并发、AI API Controller、网关及财务授权测试，确认模型不执行支付、任意命令及未经确认的真实账务写操作。

## 最终全量验证

- Rails 全量 P1–P4：**19,278 runs / 117,814 assertions / 0 failures / 0 errors / 10 skips / exit 0**，耗时 623.52 秒，四个独立进程复验；10 skips 原因见下。日志 `D:\开发\Abroa\.p4-env\logs\fix-20261125T125346Z-324292.log`，`P4_FIX_EXIT=0`。
- Brakeman 7.1.2：240 controllers、888 models、847 templates、**0 errors / 0 active warnings / 8 historical ignored / exit 0**；日志 `D:\开发\Abroa\.p4-env\logs\weo-p4-brakeman-20261125T125402Z.log`。
- API 一致性脚本通过，`ruby test/support/verify_api_endpoint_consistency.rb` / exit 0；`--compliance` 仍列出原 Sure 的 `financekit_spec.rb` OAuth、`transactions_spec.rb` 与 `transfers_spec.rb` 中行为断言不符合文档只读规则，均非本 P4 修改的端点。最新 rswag OpenAPI 重新生成：**646 examples / 0 failures / 89 documentation-only pending / exit 0**，日志 `D:\开发\Abroa\.p4-env\logs\repair-openapi-20261125T130448Z.log`，生成发生于独立测试副本，没有改写源库的 API YAML。
- 原 10 Rails skips 已于先前 `fix-20261125T122215Z-229449.log` 复核：2 Sure AutoSync 暂禁用、4 i18n 暂禁用、1 Redis 专用开关、1 DB 环境、1 API 抽象、1 Sure 消息重试待调试；未计为通过。

## 最新 SHA 独立 Docker 预生产与数据库升级

- 仅在 D 盘隔离环境构建 `abroa-p4-overlay:aae713857`（父镜像 `abroa-p3-overlay:119317b9c`），新镜像 `sha256:434b0b9a0ef9bdc829bea4a395efabb3ae11ad38decc7aa3a8bfd8b66b03a8a1`，离线 build / `bundle check` 通过；日志 `D:\开发\Abroa\.p4-repair-stage\logs\build-repair-20261125T125450Z.log`。
- 独立项目 `D:\开发\Abroa\.p4-repair-stage`，Web 仅绑定 `127.0.0.1:3048`，新 PG/Redis/Web/Worker 容器。真实 HTTP 与合成银行账本验证 A10 应收应付、A11 预测、A12 通知、A13 私有导出、A14 人工确认/执行/安全补偿、家长授权撤销 HTTP 200→404。五项 Sidekiq Cron 在 Worker 重启前后各运行并成功，`P4_REPAIR_STAGE_ALL_CHECKS_PASSED sha=aae713857` / exit 0；日志 `D:\开发\Abroa\.p4-repair-stage\logs\acceptance-repair-20261125T125654Z.log`。
- 本隔离库加密 backfill v14，dry-run / apply 均 failed_count 0、manifest 验证通过、Web/Worker 重启后 HTTP 健康，`P4_REPAIR_BACKFILL_AND_RESTART_PASSED sha=aae713857` / exit 0；日志 `D:\开发\Abroa\.p4-repair-stage\logs\backfill-repair-20261125T125841Z.log`。
- 另建 `D:\开发\Abroa\.p4-repair-upgrade`，从已存在的**只读 P3 合成测试数据库 dump** 恢复，验证项目/关系/拨款行数、现有授权对象、最新 P4 迁移、v14 加密、Web 重启成功，`P4_REPAIR_P3_UPGRADE_ALL_CHECKS_PASSED sha=aae713857 P3_source_modified=false` / exit 0；日志 `D:\开发\Abroa\.p4-repair-upgrade\logs\p3-upgrade-repair-20261125T125932Z.log`。

## 准入范围及未覆盖事项

本轮目标是 **P4.1–P4.5 后端、A10–A14 及 P1–P4 联合回归**，不代表 P5–P8、真实资金转移、Google OIDC 正式配置、真实 SMTP 外部投递、全地区银行覆盖、公开生产部署、第三方独立安全审计、393216 Token 真实完整长输出已通过。外部模型短响应 WEO 历史联调不替代上述长输出测试。原 Sure 10 skipped 和 3 项 API 文档历史合规提醒应后续单独清理，不能标记为通过。
