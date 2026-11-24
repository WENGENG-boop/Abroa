# Abroa 源码审计与复用矩阵 v1.0
基线：2026-11-24，本地 main，fc576847dcb2b33ad9ef8a9003356978fcaa4ce5。Ruby 3.4.13，Rails 8.1.4.1（.ruby-version、Gemfile.lock）。已核查目录、AGENTS.md、README、PRD、模型/API/Job 文件清单、db/schema.rb 关键表及部分模型代码、Compose 示例。以下是静态初审，不是全量行为审计；尚未运行 Rails、迁移或测试。P0 必须补齐逐项行为证据及基线测试。

|领域|本地源码/数据库证据|策略|P0 必核查|
|---|---|---|---|
|认证|users、sessions、api_keys、oidc_identities、sso_providers、webauthn_credentials；api/v1/auth_controller.rb|复用|Google issuer/subject、注册验证、登录及绑定|
|用户/租户|users.family_id、accounts.family_id/owner_id、account_shares、budget_shares；AGENTS Current.user/Current.family|复用+扩展|跨 family 默认拒绝、既有管理员/impersonation 路径|
|账户/余额|app/models/account.rb、account/current_balance_manager.rb、reconciliation_manager.rb；accounts、balances|复用|资产负债符号、余额同步、排除报告|
|账务|entries.amount/date/currency/account_id/entryable_id、transactions.extra/kind/category_id；transaction.rb、transfer.rb；API transactions/transfers/splits|复用+扩展|Entry 符号、拆分父子去重、transfer 分类例外、退款、pending|
|交易来源|entries(account_id,source,external_id) 唯一；(account_id,idempotency_key) 唯一；import_locked/user_modified；account/provider_import_adapter.rb|复用+扩展|同源重试、跨源证据合并、人工锁定优先|
|导入|imports、import_rows、import_sessions、import_mappings、import_source_mappings；transaction_import.rb、import_job.rb、revert_import_job.rb；API imports/import_sessions|复用+扩展|CSV/XLSX/PDF 真实解析覆盖、回滚、字符集|
|账单归档|account_statements，family_id/content_sha256 唯一；account_statement/account_matcher.rb、API account_statements|复用|归档不等于入账、文件大小限制及私密下载|
|银行|account_providers、各 provider items/accounts；sync_all_providers_job.rb、sync_job.rb、provider_connections_controller.rb|复用|认证、同步、撤销、提供商真实覆盖及资费|
|FX|exchange_rates(from_currency,to_currency,date) 唯一，rate>0；families.currency/enabled_currencies、accounts.currency|扩展|缺失汇率回退、历史统计、实际成交|
|预算|budgets.start_date/end_date/currency/user_id/family_id、budget_categories.rollover_enabled/rolled_over_amount；budget.rb、API budgets/budget_categories|扩展|实际按月约束、共享及分组统计；不能仅凭字段断定任意周期已支持|
|目标|goals、goal_accounts.allocated_amount、goal_pledges.matched_transaction_id 唯一；goal.rb、sweep_expired_goal_pledges_job.rb|扩展|预留、消费核销、互斥、maintained goals 与新池共存|
|费用|recurring_transactions、recurring_occurrences、recurring_allocations；generate_recurring_occurrences_job.rb、API recurring_transactions|扩展|分期、部分支付、取消、重复分配、账单状态|
|AI|app/models/ai/config/endpoint.rb、model.rb、transport/compatible.rb、router.rb、assistant/function/*；llm_usages、tool_calls；API chats/messages/usage|复用+扩展|已有写工具是否确认、所有写入口与隐私过滤、自定义端点实际协议|
|预测|insights、generate_insights_job.rb、API insights/spending_vs_normal/cash_flows|扩展|现有算法、日常基线和通知可复用|
|通知|notification_deliveries(rule_id,transaction_id) 唯一、push_deliveries、rule_email_notification_job.rb、deliver_insight_notification_job.rb|扩展|既有表非通用收件箱，邮件幂等与模板|
|商业|subscriptions.family_id 唯一、stripe_id/status；subscription.rb、stripe_event_handler_job.rb、provider_request_counts、llm_usages|复用+扩展|现有订阅 gating、价格配置、未启用真实支付、自托管免费|
|审计|security_audit_logs、sso_audit_logs、impersonation_sessions/logs、debug_log_entries|复用+扩展|平台管理员访问、脱敏、审计保存|
|报表及高级|API cash_flows/balance_sheet/holdings/trades/valuations/family_exports；holdings/trades/securities、投资与加密 provider 表|保留|全量回归；不因简洁模式删除|
|部署|Dockerfile、compose.example.yml、docs/hosting/docker.md、.env.example|复用|Web/worker、数据库、Redis、加密密钥兼容、升级恢复|

已观察到 Transaction 对 pending provider JSON 有统一 Ruby/SQL 判定，存在 pending/posted 模糊匹配及同账户合并限制，不能直接把该合并方法用于不同账户或支付渠道跨源匹配。Transaction.family_scope 通过 entry/account 的 family_id 限制；新家长接口不得直接借用学生 Current.family 访问整个租户。
银行连接器清单静态存在：Plaid、SimpleFIN、Enable Banking、TrueLayer、Wise、Akahu、Up、Lunch Flow、Sophtron、Monobank、Fio、Mercury、Brex、Redbark、FinanceKit、IBKR、Trading212、Trade Republic、Questrade、SnapTrade、Indexa、Sharesight、Binance、Coinbase、Kraken、CoinSpot、CoinStats、Onchain 等；不等于每个连接器已验证可用。
明确新增：留学项目及分摊、独立家长跨租户授权、提议、跨来源接入证据、定向拨款、留学费用扩展、预测情景、代付结算、通用通知、细粒度权益和安全确认执行。
P0 交付证据：记录 git SHA、测试环境与版本；读相关模型、控制器、路由、服务、migration、test；每项填具体方法及现有测试路径；跑原生基线，列已存在失败，不隐藏；记录真实账单样例及第三方凭证可用性；核对本套规格并修订技术差异。当前 P0 未完成。
