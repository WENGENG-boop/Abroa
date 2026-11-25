# Abroa P4 后端正式验收（2026-11-25）

**P4 后端范围验收状态：VERIFIED。** 冻结业务代码 `121519198`，分支 `abroa/development`；P1–P3 联合验收基线 `c755b002f`，P3 业务基线 `119317b9c`。不包括真实第三方模型、SMTP、OIDC、银行连接、生产公开部署、P5/P6/P7/P8 及前端。下列 A10–A14 阶段性“待验收”描述保留为当时状态，最终依据以文末签收矩阵为准。
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
- 首轮原版 Rails 全量测试：19,252 runs / 117,251 assertions / **9 failures + 2 errors** / 10 skips，`D:\开发\Abroa\.p4-env\logs\20261125T082127Z-121508.log`，退出码 1。9/2 均已定位：AI Provider 未纳入加密 backfill manifest、ReportExport blob 未纳入受保护 ActiveStorage、以及 D 盘 Windows 源文件 CRLF 导致原版换行敏感测试失败；不能宣称本次全量测试通过。
- 修复了两项真正的安全遗漏：`Abroa::AiModelProvider#api_key` 纳入 `ActiveRecordEncryptionConfig::BACKFILL_MANIFEST`，加密回填版本 13→14 并记录 SHA-256 manifest 摘要；`Abroa::ReportExport` 直接 signed blob 访问（包括本人）由 ActiveStorage 统一拒绝，必须经 Abroa 当前授权审核/审计的下载 API。
- 修复后 7 个失败相关测试家族共 134 runs / 1844 assertions / **0 failures, 0 errors, 1 skip**；`D:\开发\Abroa\.p4-env\logs\fix-20261125T084643Z-162424.log`，退出码 0。CRLF 仅在 D 盘隔离 Linux 工作副本转换，不修改 Git 源文件；安全相关改动写入代码和新增 Blob API 负向测试。新增改动 RuboCop 4 files / 0 offenses，`D:\开发\Abroa\.p4-env\logs\20261125T084944Z-168011.log`。
- 首次独立 Docker P4 预生产：冻结 `d4334f3be`、`abroa-p4-overlay:d4334f3be`，Web `127.0.0.1:3044/up` HTTP 200，P1–P4 合成账户/预算/项目/家长拨款和退款、A10 代付/还款、A11 预测、A12 站内通知、A13 CSV 私有导出、A14 预算提案确认与安全补偿，家长授权 200→404；5 个 Sidekiq Cron 重启前后执行成功。日志 `D:\开发\Abroa\.p4-stage\logs\docker-p4-acceptance.log`，退出码 0；该冻结镜像尚不含后续安全修复，必须在新 SHA 上复验。
- 修复后原版 Rails 全量四进程隔离复验已开始，日志 `D:\开发\Abroa\.p4-env\logs\fix-20261125T084924Z-167234.log`，尚待最终结果；生产容器 P4 加密 backfill v14 和最终冻结 SHA 复验待执行。
- 未验证真实外部模型凭证；AI 对导入匹配和分类当前仅建议，后续仍须原用户审核，禁止自动过账。

## P1–P4 后端联合正式验收（2026-11-25）

**SIGNED — P4 BACKEND VERIFIED（仅 P4.1–P4.5 后端阶段与 P1–P4 集成范围）。** 冻结业务提交：`121519198`。P1/P2/P3 已冻结的历史提交及预生产数据不变；下方全部证据来自 D 盘隔离环境。完成验收不表示公开生产部署或者未配置的第三方服务已经验证。

| 最终验收门槛 | 实际结果与证据 |
|---|---|
| Rails 原版全量 P1–P4 回归（修复后） | **19,253 tests / 117,659 assertions / 0 failures / 0 errors / 10 skips / exit 0**；`D:\开发\Abroa\.p4-env\logs\fix-20261125T084924Z-167234.log`。测试以四个独立进程运行，Windows 原始文件的 CRLF 差异仅在隔离测试副本归一化，正式源码未改。 |
| 首轮回归问题及补救 | 首轮 19,252/117,251、9 failures/2 errors/10 skips；真实缺陷为 A13 私有导出 signed blob 授权遗漏及 A14 API Key backfill 未登记；其余为环境换行符；修复后涉及的七组测试 **134/1844/0 failures/0 errors/1 skip**，详见本文件前文记录。 |
| A10–A14 及 Sure AI/MCP 组合回归 | 432 tests / 2,814 assertions / 0 failures / 0 errors；`D:\开发\Abroa\.p4-env\logs\20261125T081840Z-117651.log`。预算/费用/资金池写入二次确认和补偿、Grant 即时撤销、归档导出与只读投影覆盖。 |
| PostgreSQL 真实并发与迁移 | A10 两连接 2/11、A12 两连接 2/8、A14 两连接 1/7 全通过；P4.1/P4.3/P4.4/P4.5 迁移往返、schema 同步。 |
| 安全扫描/代码规范 | 最终 Brakeman **240 controllers / 888 models / 0 errors / 0 active warnings / 8 historical ignored**, exit 0，`D:\开发\Abroa\.p4-env\logs\20261125T085823Z-189229.log`；新增安全改动 RuboCop 4 files / 0 offenses，`D:\开发\Abroa\.p4-env\logs\20261125T084944Z-168011.log`。审查由实现代理进行，不等于独立第三方审计。 |
| OpenAPI、端点一致性 | rswag **646 examples / 0 failures / 89 documentation-only pending**，`D:\开发\Abroa\.p4-env\logs\20261125T081508Z-113037.log`；最终端点一致性检查 exit 0，`D:\开发\Abroa\.p4-env\logs\20261125T085907Z-191047.log`。 |
| 新 P4 独立 Docker 预生产 | 冻结镜像 `abroa-p4-overlay:121519198`（`sha256:5a4ca7f25dea...`）。独立 PostgreSQL/Redis/Web/Worker，Web 仅 `127.0.0.1:3044`；P1/P2/P3 合成金融账本、P4.1 债务/还款、P4.2 预测、P4.3 通知、P4.4 CSV、P4.5 AI 提案确认/补偿、家长 Grant 200→404；五项 Sidekiq Cron 在 Worker 重启前后均通过；`D:\开发\Abroa\.p4-stage\logs\docker-p4-acceptance.log` 记录 `P4_STAGE_ALL_CHECKS_PASSED sha=121519198`，exit 0。 |
| 新的加密回填 v14 | 在 **仅 P4 隔离 stage** 中先 dry-run 后实际执行，均 0 失败；2 位用户、2 个 API Key、1 个 AI Model Provider 完成加密回填，状态版本 14、Web/Worker 重启通过；`D:\开发\Abroa\.p4-stage\logs\p4-v14-encryption-upgrade.log`。 |
| P3 历史测试库升级 | 从 P3 原库只读 pg_dump，复制至新 `abroa-p4-upgrade` 项目（Web 仅 `127.0.0.1:3045`）；8 项目、6 关系、4 收款记录与来源计数一致；P4 迁移、旧 Grant/项目读取、v14 回填、Web 重启全部通过，`D:\开发\Abroa\.p4-upgrade\logs\p3-to-p4-upgrade.log` 记录 `P3_TO_P4_UPGRADE_ALL_CHECKS_PASSED sha=121519198 P3_source_modified=false`，exit 0。 |

**明确不在此次验收范围**：生产公网发布、真实银行与支付通道、真实 SMTP 发信/外部收件、实际 Google/OIDC 配置、第三方模型及自托管推理服务真实联网、外部对象存储、独立安全审计、P5 管理运营/部署、P6 全后端终验及 P7/P8 前端发布。10 个 Rails skipped、89 个 Swagger pending 没有当作通过的测试。所有 HTTP/现金记录均为隔离合成数据；没有更改 P2/P3 冻结库。

最终签署状态：**P4 BACKEND VERIFIED — SCOPE LIMITED**。源码冻结 SHA `121519198`；后续仅文档签收提交不改变此冻结业务镜像。
