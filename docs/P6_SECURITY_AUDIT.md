# Abroa P6 — 独立后端安全审计（P6.2）

审计日期 2026-11-26。继承 SHA `a339eff9343c8da94ae88ed6b9c4f23eda60bc59`；P6.1 SHA `421c68e13ed9f547045d166318d27a594e2e4063`。测试环境为仅 D 盘 WSL Docker PostgreSQL 17 / Redis 7 / Rails test。所有证据日志位于 `D:\开发\Abroa\.p6-env\logs`；真实生产银行、客户资金、生产密钥均未访问。

## 认证、授权、账务及模型边界

| 安全威胁 | 源码与边界 | P6 真实负向测试与结论 |
|---|---|---|
| 学生/家长跨租户 IDOR、撤权后旧授权 | `Abroa::Relationship`、`Grant`、`ParentOverview`、`ReportExport`，以及继承 Sure 的 `Api::V1::BaseController` | P6 家长 13/89、黄金场景 1/40 全通过。外国项目 404、授权撤销后 404、家长摘要不含原始账户名称和 ID；继承的 Sure transactions API 不泄露学生原始账本。 |
| 账务重放、重复确认、竞争超额核销 | `EntryAllocation`、`FeeSettlement`、`FundPool`、`DebtSettlement` 与 PostgreSQL 索引/锁 | P6 财务并发 8/31、完整回归 19,330/118,236 均通过。两个项目分摊 60+30 GBP，超额再分摊 20 GBP 被拒，账本不增加；50 GBP 分期核销重复请求返回原结果；保留原 Entry 金额。 |
| 恶意 LLM 输入、工具执行、旧建议重放 | `AiModelProvider`、`AiModelGateway`、`AiProposal`；模型输出不等于授权指令 | P6 AI 37/216，含无模型、超时、无效响应、越权工具、重复及并发确认，均 0 failure/error。未配置真实模型时使用确定性替身；未把模拟视为真实第三方联调。 |
| AI endpoint SSRF/DNS rebinding | Provider URL 语义校验、网关解析公网 IP 和固定目标、禁重定向 | 针对性网关测试已覆盖内网/保留 IPv4/IPv6、HTTPS 主机约束；自托管例外由管理员显式名单授权。远端传输未实连。 |
| API Key、OAuth、账单及模型密钥泄漏 | Sure API Key/OAuth 鉴权、`AiModelProvider` 加密字段、平台角色与脱敏审计 | P6 平台 32/223，0 失败；合法 API 客户端支持 API Key 与 OAuth，FinanceKit rswag **必须保留两种**；扫描器“rswag using OAuth”是宽泛启发式提示，不能移除实际有效的 OAuth 认证。 |
| Report、附件/CSV 公式及过期权限 | `ReportExport` 每次读取重鉴权、家长授权 digest、CSV 公式前缀防护、下载时效及摘要哈希 | 源码审查与继承行为测试通过，黄金场景确认家长看不到私人字段。真实外部对象存储、邮件附件链接未联调。 |
| 平台审计 UPDATE/DELETE 绕过 | `PlatformAuditEvent` Rails readonly + PostgreSQL `abroa_platform_audit_immutable` BEFORE UPDATE/DELETE trigger | **实际直接 SQL** 修改与删除均退出 1、错误 `Abroa platform audit is append-only`，记录字段未变，见 `p6-runtime-recovery.jsonl`。 |
| Web/Worker 宕机后不一致、密钥失效 | Docker P6-only fault runner，PG/Redis 重试，账本行指纹 | `verify_runtime.py` exit 0：Web 和 Worker 重启、Sidekiq 队列 1→0、Redis 中断拒绝/恢复 PONG、PG 中断超时/恢复 SELECT1、测试加密密钥重启后可解，财务指纹全程一致，GET /up 恢复 200。 |
| 平台人员读取未授权财务明细/账号封禁后通行 | 平台角色/用户/操作 Controller、旧 Sure 登录及 impersonation 边界 | P6 平台专项 32/223、历史全量 19,330/118,236/0/0/9。已在代码级核查平台数据汇总入口不直接导出未授权 Entry；真实生产 session/外部 OAuth 撤权窗口须真实联调。 |

### 静态、端点、文档与历史警告

- Brakeman `bundle exec brakeman -q --no-pager`：退出 **0**；243 controllers / 902 models / 847 templates；0 errors、0 unignored security warnings；**8 inherited ignored warnings + 1 obsolete ignore entry**，见 `p6-brakeman.log`。八项历史忽略涉及 SnapTrade OAuth 外部跳转、受家庭管理员保护的导出、Trade/RecurringAccount 的 ID 归属、管理员变更、邀请角色、动态表单生成与导入配置局部模板。它们都属于原 Sure 旧实现，源码显示家庭作用域、管理员或服务端名单限制；保留忽略项及审查来源，未擅删警告来变绿。不将“8 ignored”宣称为“0 历史风险”。
- 原版全 Rails 回归 **19,330 runs / 118,236 assertions / 0 failures / 0 errors / 9 skips**，退出 0，见 `p6-full-regression-serial.log`。新添加注册/OAuth/引导测试 1/29 和外币导入测试 1/4 已分别通过；最后完整合并回归仍需单独留存最终退出码。
- 全库 Ruby RuboCop **3,884 files / 0 offenses / exit 0**（首次 14 项均为旧版迁移数组间距，格式修复后独立复跑）见 `p6-rubocop-full-final.log`。ERB Lint **857 files / 0 errors / exit 0**，`p6-quality-erb_lint.log`。
- Biome v1.9.4 在 D 盘独立安装。JS **lint 158 files / 0 errors / exit 0**，`p6-biome-lint.log`；额外的 `biome check .` 将格式检查扩展到原有 JS 和 biome.json，检出 **163 格式诊断**，未为清零而批量修改 P7 前端代码，日志 `p6-biome-check.log`，**全仓格式检查并未通过**。
- API Endpoint Consistency 和 `--compliance` 退出 0，所有 API v1 控制器有对应 Minitest；FinanceKit OAuth 文档的启发式提示非缺陷，`p6-api-consistency.log`。rswag 生成 676 examples / 0 failures / 89 文档型 pending，退出 0，`p6-rswag.log`；pending 不计为功能测试通过。旧 rswag 的交易外币、转账费用行为断言已转/保留在 Minitest，未取消实际业务断言。

### 9 个历史 skips 的逐一审查

P6 使用与全量一致的 `SELF_HOSTED=false` 单独执行 `rails test --verbose` 共 **220 runs / 1305 assertions / 0 failures / 0 errors / 9 skips**，退出 0，见 `p6-skipped-test-audit.log`：
1. `I18nTest#test_files_are_normalized`：仓库主动跳过文件规范化检查。
2. `I18nTest#test_no_missing_keys`：仓库主动跳过翻译缺项。
3. `I18nTest#test_no_unused_keys`：仓库主动跳过闲置翻译键。
4. `I18nTest#test_no_inconsistent_interpolations`：仓库主动跳过翻译插值一致性。
5. `RecurringTransaction::PipelineTest#test_the_resolved_connection_config_exposes_a_username`：当前指定 `DATABASE_URL` 覆盖 `database.yml`。
6. `Api::V1::BaseControllerTest#test_should_provide_current_resource_owner_method`：作者注释“Will test via test controller implementation”。
7. `AutoSyncTest#test_auto-syncs_family_if_hasn't_synced`：继承 Sure 的自动同步暂时禁用。
8. `AutoSyncTest#test_auto-syncs_family_if_hasn't_synced_in_last_24_hours`：同上。
9. `UsageRedisTest#test_independent_worker_processes_share_atomic_claims_for_installation_events`：只有设置 `DAILY_USAGE_REDIS_TESTS=1` 并使用一次性 Redis 才执行。P6 故障测试已经真正运行隔离 Sidekiq Redis 队列，但不能宣称等价替代此跳过测试。

### 阶段内真实/模拟界限

真实 Google OAuth 第三方回调、支付宝/微信及银行生产连接、外部模型服务、SMTP 投递、收费回调及生产环境网络仍为外部未验证项。源码/fixture 检查不代表远端联调完成。System Browser UI tests 需要 Selenium ChromeDriver 环境，初始本地容器不能启动浏览器；这是测试基础设施条件，不能将该轮错误记录为业务逻辑通过。

### 无真实外部凭证时的独立代码调用链审查

以下检查仅针对实际源码调用链、授权及存储约束，结论是**模拟边界通过/真实服务未联调**，不伪称远程请求成功：

| 外部依赖 | 实际源码调用链 | 身份与财务约束、独立审查结论 |
|---|---|---|
| Google OAuth/OIDC | `app/controllers/sessions_controller.rb#openid_connect` → `app/models/abroa/google_identity.rb#claims!` / `matches?` → `OidcIdentity` 与用户会话 | 回调来源为 OmniAuth 服务端验签后的 `auth`，再次要求受信发行方 `accounts.google.com`、非空 `sub` 与 UID 一致、邮箱与 auth.info 一致且 `email_verified=true`；保留用户/设备实际有效性检查。P6 新用户本地 OAuth Token 登录 1/29 通过，**Google 远端 callback 未联调**。 |
| Plaid/TrueLayer 等银行连接 | `app/models/plaid_item/importer.rb#import` → `fetch_and_import_item_data` → `fetch_and_import_accounts_data` → `PlaidAccount::Importer`，另有 `app/models/truelayer_item/importer.rb`；完成后 `app/jobs/abroa/provider_capture_job.rb` 扫描已提交原始账本 | 账号发现与入账包裹在 `PlaidItem.transaction`，**只在全部账户导入成功后保存游标**；对再次授权的新 account_id 用 persistent_account_id 匹配旧账户、优先已链接账户，旧数据不能凭同金额简单合并；旧 Sure Entry 和 `account_id + source + external_id` PG 唯一索引阻止真正重复写入，P6 性能数据库直接重复 INSERT 实测被拒。银行真实 API/同步 webhook 未调用。 |
| 支付宝/微信/文件入账 | `Abroa::StatementIntake` / `StatementReconciliation` / `SourceReview` 控制器与模型、继承的 Sure `Import` / `Entry`，P6 新项目分摊和报表复测 | API Key/OAuth 身份 → 家庭与账户归属校验 → 预览/复核 → 已确认原始 Entry，仅产生具备幂等键的分配，不会由 AI 文本或模板直接写真实余额；内容/CSV 公式净化由对应导出入口负责。文件夹/测试数据为合成 fixture，**真实个人微信/支付宝账单未获取**。 |
| AI 模型网关 | `app/models/abroa/ai_model_provider.rb` → `ai_model_gateway.rb` 的 URL/IP/TLS 与凭证限制 → AI proposal 产生**建议** → 具有当前权限和版本号的显式用户确认才可提交 | `api_key` 加密存储、输出脱敏、HTTPS 公网目标验证及连接目标固定 IP，拒绝非预期工具调用/提示注入；P6 AI 37/216 测试通过。无外部模型密钥调用记录，不允许模型直接执行真实付款。 |
| SMTP/站内通知 | `app/models/abroa/email_outbox.rb#eligible_now?` → `app/jobs/abroa/email_outbox_delivery_job.rb#perform` → `AbroaNotificationMailer.generic` | 发送前锁出站记录、再次检查 recipient.active、家庭一致、用户偏好和当前通知 Grant；`sent/cancelled/sending/uncertain` 不盲重发。明确 SMTP 拒绝可延迟最多 5 次，连接超时等**不确定已送达**标记 `uncertain`，不以幂等假象重复发送。外部 SMTP 收件箱未验证。 |
| 订阅/收费回调 | `app/models/abroa/service_billing_event.rb#simulate!` → `ServiceSubscription` / `PlatformRoleAssignment` | 模拟事件强制 `amount=nil,currency=nil,status=simulated`，必须为当前用户自己的订阅、同一个 `external_id` 重放返回原事件、变更冲突拒绝，用户行加锁；仅有 `operations.write` 的平台角色可以变更套餐。**没有真实扣款、模拟未变成真实付款成功**，真实供应商 webhook/退款未联调。 |
| FX provider | `app/models/abroa/rate_snapshot.rb#quote` → 已持久化 `ExchangeRate` 查询 → 精确/五天历史回退/缺失状态 → 后端只读报表与分配 | 原币金额不修改，货币小数位由 `Money::Currency` 校验；缺失汇率返回 incomplete 而不凭空估值。历史 GBP/USD/JPY 等由专用 Minitest/fixture 覆盖，实时 FX 供应商尚未联调。 |

P6 真实 HTTP、数据库约束和模型负向测试构成模拟验收；实际第三方网络握手、回调防重放与生产验收另列 P8，不将“未联网”记为已验证联网。

## Final PostgreSQL and Redis concurrency proof (2026-11-26)

The originally conditional Sure `UsageRedisTest` was explicitly executed against P6's **Redis database 12** with `DAILY_USAGE_REDIS_TESTS=1`. Eight forked worker processes concurrently attempted the same daily event claims: **1 Minitest / 36 assertions / 0 failures / 0 errors / 0 skips, exit 0**, full log `D:\开发\Abroa\.p6-env\logs\p6-redis-atomic-claims.log`. The nine skips in the normal complete Rails run remain historically accounted for and are not silently relabeled; this particular test has separate positive evidence.

An independent P6-only Sidekiq job with a purposely failing first attempt was queued through real Redis, retried and completed on the second attempt: `p6-sidekiq-retry-real.log`, exit0, counted exactly 2 attempts, final Redis completion flag yes. Its temporary fixture was removed from the test-only snapshot. P6 cloud Web+Worker were also verified healthy in `SELF_HOSTED=false`, live internal HTTP200 health and 401 unauthorized response (`p6-cloud-runtime.log`, exit0). These are real local service tests, not live third-party finance tests.
