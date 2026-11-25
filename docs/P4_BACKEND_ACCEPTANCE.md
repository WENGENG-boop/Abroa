# P4 后端验收记录（进行中）

基线：`abroa/development`，P1–P3 联合验收提交 `c755b002f`。
验收要求：A10–A14 全部通过，完整 Rails 测试集、OpenAPI、Brakeman、安全、迁移、Docker 独立预生产及跨阶段联调全部完成后方可签署 `P4 BACKEND VERIFIED`。本文件不得代替实际日志。

## P4.1 / A10 应收应付
当前状态：已实现首版，**等待正式阶段验收及 P1–P4 联合验收**，不能标记为 P4 VERIFIED。
- 数据：`db/migrate/20261125110000_create_abroa_personal_debts.rb`，`20261125110500_add_source_refunds_to_abroa_debt_settlements.rb`。
- 财务模型：`app/models/abroa/personal_debt.rb`、`debt_settlement.rb`、`debt_consumption.rb`、`net_consumption.rb`。
- API：`app/controllers/api/v1/abroa/personal_debts_controller.rb`、`debt_settlements_controller.rb`，`config/routes.rb`。
- 用例：`test/models/abroa/personal_debt_test.rb`、`test/controllers/api/v1/abroa/personal_debts_controller_test.rb`；rswag 描述位于 `spec/requests/api/v1/abroa/p4_debts_spec.rb`。
- 实际完成的专项运行：11 tests / 74 assertions / 0 failures / 0 errors，`D:\开发\Abroa\.p4-env\logs\20261125T061954Z-340609.log`，退出码 0。
- RuboCop：10 files / 0 offenses，`D:\开发\Abroa\.p4-env\logs\20261125T062126Z-342307.log`，退出码 0。
- API 端点一致性：通过，`D:\开发\Abroa\.p4-env\logs\20261125T061339Z-333829.log`，退出码 0。
- Brakeman：Rails 8.1.4.1 / Brakeman 7.1.2，0 errors / 0 active warnings / 8 既有忽略记录，`D:\开发\Abroa\.p4-env\logs\20261125T061411Z-334468.log`，退出码 0；该运行早于源码退款处理变更，需在最终验收重跑。
- 账务：真实 Sure 银行 Entry 关联，不创建现金流水，不直接修改银行余额；`OtherAsset` / `OtherLiability` 账户和 Valuation 表示债权债务。收款非收入、还款非重复费用，支持历史 FX、幂等、退款、取消及跨账户隔离。
- 实际 PostgreSQL 双连接并发：2 tests / 11 assertions / 0 failures / 0 errors，`D:\开发\Abroa\.p4-env\logs\20261125T063041Z-352619.log`，退出码 0。测试覆盖竞争超额结算和同一幂等确认，断言不同 PG backend PID。
- A10 往返迁移：先 10500 down→up，再 10500 down→110000 down→110000 up→10500 up，`D:\开发\Abroa\.p4-env\logs\20261125T062520Z-346747.log`，退出码 0。检查的是独立 P4 测试库，不代表已执行 P3 预载历史数据升级。
- A10 扩大回归：271 tests / 1694 assertions / 0 failures / 0 errors，`D:\开发\Abroa\.p4-env\logs\20261125T062204Z-343081.log`，退出码 0（新并发用例另计）。
- 未完成证据：完整 Rails 回归、P3 真实历史数据迁移保留验证、Docker 预生产及 P1–P4 跨阶段财务闭环。

## P4.2 / A11 预测
当前状态：已实现确定性预测核心、学生及受限家长 API、情景模拟；待阶段回归与 P1–P4 联合验收，**不得标记 P4 VERIFIED**。
- 代码：`app/models/abroa/forecast.rb`、`app/models/abroa/net_consumption.rb`、`app/controllers/api/v1/abroa/forecasts_controller.rb`、`config/routes.rb`。
- 用例：`test/models/abroa/forecast_test.rb` 和 `test/controllers/api/v1/abroa/forecasts_controller_test.rb`；最新专项运行 13 tests / 70 assertions / 0 failures / 0 errors / 0 skips，`D:\开发\Abroa\.p4-env\logs\20261125T065155Z-11512.log`，退出码 0。
- RuboCop：最终变更 5 files / 0 offenses，`D:\开发\Abroa\.p4-env\logs\20261125T070005Z-20910.log`，退出码 0。
- A10–A11 及相关 Abroa 模块最终阶段回归：288 tests / 1788 assertions / 0 failures / 0 errors / 0 skips，`D:\开发\Abroa\.p4-env\logs\20261125T065903Z-19728.log`，退出码 0。
- 关键缺陷回归：P4.1 未来到期日修复提交 `67ab830b2`，个人实际发生日期仍禁止未来；A10+A11 合并专项 24 tests / 139 assertions 通过，`D:\开发\Abroa\.p4-env\logs\20261125T065747Z-18220.log`。
- Brakeman 完整扫描：237 controllers / 875 models，0 errors / 0 active warnings / 8 既有 ignored，`D:\开发\Abroa\.p4-env\logs\20261125T070026Z-21395.log`，退出码 0。
- rswag OpenAPI 生成：626 examples / 0 failures / 89 pending (仅文档样例)，`D:\开发\Abroa\.p4-env\logs\20261125T065435Z-14615.log`，退出码 0；YAML 包含两条预测 API。
- 账务及安全：使用实际 Sure depository 余额、过去 30 日日常净消费、已付固定费用排除及剩余分期、未到账拨款假设、真实 FX 历史汇率快照；预测不写真实 Entry，模拟资金池目标不视为现金。数据缺失返回 incomplete/null，父母访问需实时核实四项 Grant 并去除个人私密债务和原始交易。
- 等待验证：完整 Rails 全量、Docker stage HTTP、长项目与极端数据压力、跨阶段 P1–P4 闭环、最终审查签收。

## P4.3 / A12 通知
阶段实现状态：已写入站内通知、邮件 Outbox、发送/重试/恢复 Worker、P2/P3/Sure 事件聚合和 API；尚待 P1–P4 全量联合验收。
- 数据：`db/migrate/20261125120000_create_abroa_notifications.rb` 创建 `abroa_notification_preferences`、`abroa_inbox_notifications`、`abroa_email_outboxes`，均有租户引用、唯一约束或状态 CHECK。
- 模型：`app/models/abroa/{notification_preference,inbox_notification,email_outbox}.rb`；API：`app/controllers/api/v1/abroa/notifications_controller.rb`、`config/routes.rb`。
- 异步：`app/jobs/abroa/{notification_event_sweep_job,email_outbox_sweep_job,email_outbox_delivery_job,email_outbox_recovery_job}.rb`；`app/mailers/abroa_notification_mailer.rb`；Sidekiq `config/schedule.yml`。
- 测试：`test/models/abroa/{inbox_notification,notification_event_sweep,notification_concurrency}_test.rb` 与 `test/controllers/api/v1/abroa/notifications_controller_test.rb`。本地邮箱/模拟 SMTP；跨时区偏好、默认邮件关闭、错误收件人/跨租户、读写 API 权限、撤销 Grant 后取消投递、幂等通知/已读、Worker 中断和 SMTP 拒绝重试。
- 单元/API 专项：17 tests / 88 assertions / 0 failures / 0 errors，`D:\开发\Abroa\.p4-env\logs\20261125T071759Z-41127.log`，退出码 0。
- 双 PostgreSQL 并发：2 tests / 8 assertions / 0 failures / 0 errors（同一事件及 Outbox 唯一、重复发送只接受一次），`D:\开发\Abroa\.p4-env\logs\20261125T071848Z-42167.log`，退出码 0。
- 迁移往返：20261125120000 down/up 均成功，`D:\开发\Abroa\.p4-env\logs\20261125T072007Z-43749.log`，退出码 0。
- P1–P4 Abroa 范围扩大回归：307 tests / 1884 assertions / 0 failures / 0 errors / 0 skips，`D:\开发\Abroa\.p4-env\logs\20261125T072401Z-48659.log`，退出码 0（不是完整 Rails 全库）。
- RuboCop：14 files / 0 offenses，`D:\开发\Abroa\.p4-env\logs\20261125T072334Z-48004.log`，退出码 0。
- Brakeman 全库：238 controllers / 878 models，0 errors / 0 active security warnings / 8 previously ignored，`D:\开发\Abroa\.p4-env\logs\20261125T072506Z-49971.log`，退出码 0。
- rswag OpenAPI：630 examples / 0 failures / 89 pending（文档专用），`D:\开发\Abroa\.p4-env\logs\20261125T072206Z-46355.log`，退出码 0；涵盖收件箱、标记已读和偏好。
- 隐私策略：无银行、交易金额、用户输入联系人或敏感字段写入邮件；发送前现时授权+收件人一致性校验。SMTP 传输结果不确定时状态 uncertain，禁止自动盲目重发。
- 未验证：第三方真实 SMTP 凭证/投递、独立 Docker Worker 重启恢复、P1–P4 全量验收。

## P4.4 / A13 报表
阶段状态：真实 Sure Ledger 对账 + 安全导出业务实现及阶段测试通过；仍待 P1–P4 整体验收。
- 报表服务：`app/models/abroa/financial_report.rb`、`project_debt_recognition.rb`，只读复用 Sure IncomeStatement/NetConsumption、P2 ProjectSummary/预算/分期费用/资金池、P3 FundingPlan 和 P4 应收应付/RateSnapshot。项目 800 GBP 代付含自担 200/他担 600；商户退款 400 GBP 与还款 200 GBP 不重复减个人消费。
- 安全导出：`db/migrate/20261125130000_create_abroa_report_exports.rb`、`app/models/abroa/report_export.rb`，原生 ActiveStorage 私有附件、用户+租户范围、7 天有效期、最大 2 MB、内容 SHA-256、稳定幂等、跨租户隔离、CSV 全单元格公式防注入；每次下载实时鉴权并审计。家长 Grant 撤销后已有导出不可下载/不可重放。
- API 与文档：`app/controllers/api/v1/abroa/reports_controller.rb`，`config/routes.rb`，`spec/requests/api/v1/abroa/p4_reports_spec.rb`，`docs/api/openapi.yaml`。
- A13 Minitest 账户/项目/家长/FX/退款/导出/CSV/审计/API：12 runs / 91 assertions / 0 failures / 0 errors / 0 skips，`D:\开发\Abroa\.p4-env\logs\20261125T073843Z-65272.log`，退出码 0。
- A10–A13 Abroa 扩大联合回归：319 runs / 1975 assertions / 0 failures / 0 errors / 0 skips，`D:\开发\Abroa\.p4-env\logs\20261125T074219Z-70239.log`，退出码 0。
- RuboCop：8 files / 0 offenses，`D:\开发\Abroa\.p4-env\logs\20261125T073849Z-65553.log`，退出码 0。
- 数据库 20261125130000 down/up 成功：`D:\开发\Abroa\.p4-env\logs\20261125T073939Z-66660.log`，退出码 0。Schema 已重新生成。
- rswag Swagger：634 examples / 0 failures / 89 pending（文档占位），`D:\开发\Abroa\.p4-env\logs\20261125T074121Z-68987.log`，退出码 0。
- Brakeman A13 代码扫描：239 controllers / 881 models，0 errors / 0 active security warnings / 8 pre-existing ignores，`D:\开发\Abroa\.p4-env\logs\20261125T074403Z-72644.log`，退出码 0。
- 仍待：真实 Docker P4 stage、P3 真实历史数据升级、全 Rails Minitest 全量与跨阶段链路、外部真实对象存储。

## P4.5 / A14 AI 财务助手
当前状态：**IN_PROGRESS**。业务代码及隔离 PostgreSQL 验证在进行中，不等于正式 P4 验收。
- Provider/Usage/Proposal 三张可逆表：`db/migrate/20261125140000_create_abroa_ai_financial_assistant.rb`。API Key 使用 Rails `encrypts`，只返回遮罩，记录调用次数、Tokens、成功率，未知模型成本保留 NULL。
- 模型网关采用公共 HTTPS hostname + DNS 全结果公网校验、IP pin、证书校验、无代理/重定向，限制超时和响应体；自托管只允许管理员精确白名单 `ABROA_AI_ALLOWED_LOCAL_ENDPOINTS` 指定私网 IPv4 端点，默认拒绝所有本地/metadata。
- 财务问答与交易分类只读；家长只能访问当前有效 P3 Grant 聚合。Sure Chat/MCP 注册表和 FunctionToolCaller 双层禁止 Abroa 用户使用旧财务写工具直接执行。
- 写操作仅开放预算限额、费用调整、虚拟资金池分配三项原有 P2 业务域接口；提案+随机 token+15 分钟+版本及状态 digest，明确用户确认之后才能执行。确认过期、权限撤销、二次执行和并发重放防护，安全补偿拒绝覆盖后续操作。
- 相关代码：`app/models/abroa/ai_*.rb`、`app/controllers/api/v1/abroa/ai_controller.rb`、`app/models/assistant.rb`、`app/models/assistant/function_tool_caller.rb`，`spec/requests/api/v1/abroa/p4_ai_spec.rb`。
- A14 专项：21 tests / 159 assertions，0 failures / 0 errors，日志 `D:\开发\Abroa\.p4-env\logs\20261125T081250Z-109900.log`，退出码 0。
- 双真实 PostgreSQL session 并发：1 test / 7 assertions，0 failures / 0 errors，日志 `D:\开发\Abroa\.p4-env\logs\20261125T081344Z-111028.log`，退出码 0。
- RuboCop：14 files / 0 offenses，`D:\开发\Abroa\.p4-env\logs\20261125T081438Z-112240.log`。
- A10–A14 Abroa 及 Sure 既有 AI ToolCaller/MCP 扩大回归：432 tests / 2814 assertions / 0 failures / 0 errors / 0 skips；`D:\开发\Abroa\.p4-env\logs\20261125T081840Z-117651.log`，退出码 0。
- Brakeman 全库 240 controllers / 888 models / 0 errors / 0 active warnings / 8 历史 ignored；`D:\开发\Abroa\.p4-env\logs\20261125T082005Z-119725.log`，退出码 0。
- rswag OpenAPI：646 examples / 0 failures / 89 documentation-only pending；`D:\开发\Abroa\.p4-env\logs\20261125T081508Z-113037.log`，退出码 0。
- 最新 Schema 同步完成；`D:\开发\Abroa\.p4-env\logs\20261125T081945Z-119134.log`，退出码 0。
- 未验证真实外部模型凭证；AI 对导入匹配和分类当前仅建议，后续仍须原用户审核，禁止自动过账。
- 原版 Rails 全量套件已启动、等待退出码，日志 `D:\开发\Abroa\.p4-env\logs\20261125T082127Z-121508.log`；完整 Docker P4 独立阶段验收待执行。

## P1–P4 联合验收
尚未执行完毕。需最终记录逐模块结果、测试与断言、退出码、修复提交 SHA、数据库回滚、Docker 端点、授权撤销与外部验证缺口。

正式签署状态：**NOT VERIFIED**。
