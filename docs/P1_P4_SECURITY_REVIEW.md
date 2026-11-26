# Abroa P1–P4 安全审计（独立验证）

审核日期：2026-11-26；代码基线：38adcae14cff6d04987b7e1e39745c6467899c8d。检查包括当前 Rails 全量/专项数据库测试、真实隔离容器 Web API、权限撤销、并发、密钥、加密回填、Brakeman 与人工源码复核。注意静态审计不等于渗透测试。

## 本轮扫描结果

Brakeman 7.1.2，Rails 8.1.4.1、Ruby 3.4.13：0 active warnings / 0 scan errors / exit 0。JSON 证据：D:\开发\Abroa\.p1-p4-full-20261126\logs\brakeman-full.json。

存在 **8 项历史忽略的原 Sure 警告**，应从 active=0 单独登记；高置信度 2 项：app/controllers/recurring_transactions_controller.rb 的 account_id strong params，以及 app/controllers/api/v1/trades_controller.rb 的 account_id strong params。其他 6 项包括 SnapTrade/FamilyExports 重定向、Invitation/Admin 用户角色赋值及 StyledFormBuilder class_eval。这些是基线 ignore 不是本轮新发现的 Abroa 活跃漏洞；不得因为 scanner 返回 0 就声称“历史忽略不存在”。

已读两处 High 提示的实际调用链：TradesController#create 使用 current_resource_owner.family.accounts.writable_by(...).visible.find；转账目的账户由 writable_transfer_account_id 重新检查。RecurringTransactionsController 通过 RecurringTransaction::DeclaredBill 构造，更新入口将 account_id 排除直接 permit 并在 apply_editable_identity 通过 Account.writable_by(Current.user) 查找。审计仍须复核 DeclaredBill 对创建 account_id 的拒绝路径，以及对旧忽略其他 6 项的独立风险接受依据；不能自动标为已修复。

## ABROA 跨租户与财务边界

- 真实隔离 API 合成链路：先授权家长查看成功（HTTP 200），撤销授权后重新访问返回 HTTP 404。P4 报告下载依赖重新检查访问权限；不是仅凭下载 token 的静态文件服务。
- P2 资金池/拨款均为内部意向及资金来源证明；模型调用禁止通过 AI 发起真实支付、修改账户余额或执行任意系统命令。P4 AI proposal 为 proposed→confirmed→executed / rejected / compensated 独立状态，要求单次明确确认及当前用户权限、版本、状态摘要一致。
- A14 本轮实际本地 OpenAI Chat Completions HTTP 测试：使用 127.0.0.1 上 TCPServer，验证 Bearer、JSON 格式、401、302→metadata 拒绝、错误 JSON、Token length/incomplete、API key 不入明文持久化；不是第三方官方模型的联网验证。脚本：test/models/abroa/ai_model_gateway_local_endpoint_test.rb。
- AiModelGateway 校验 URL/DNS，拒绝私有/保留地址、无凭证重定向、禁止环境代理、DNS IP pinning、TLS 验证、消息长度、超时、异常响应结构、输出 token/消息字节；本地 HTTP 端点仅自托管管理员以精确白名单开放。人工复核路径：app/models/abroa/ai_model_gateway.rb、ai_model_provider.rb。
- 真正并发：test/models/abroa/ai_proposal_concurrency_test.rb 两个 PostgreSQL backend PID 不同，测试同一提议同时确认只一成功、并行执行只产生一次审计记录。已包含本轮 496 项专项测试。
- 原始 P3 备份保持只读；P3→P4 升级验证加密回填 dry-run 与 apply 均 failed_count=0。未在 C 盘存储任何测试凭证；所有新密码是隔离环境的随机临时值且仅存 D 盘专用 .env。
- Brakeman 0 active 不能替代证明旧 ignored warnings 已安全消除；这一点作为未完成的人工审计签核项保留。

## 范围边界

真实支付、真实银行、真正发送邮件、真实 Google OAuth、外部模型凭证、生产部署及生产密钥轮换未获授权/不属于此测试。需在独立外部集成验收报告中记录，不能推断已通过；第三方模拟与真实服务明确区分。

判定：本轮没有活跃 Brakeman 警报，专项安全回归全绿；但历史 ignored High 及逐条需求矩阵仍需补齐证据，故 **SECURITY REVIEW NOT YET SIGNED OFF**。

## 续验安全证据（2026-11-26）

- Sure 历史 ignored High 的真实权限测试（Trades API + DeclaredBill）新增独立复测证据：93 runs / 447 assertions / 0 failures / 0 skips。账号可写范围和错误权限返回均受测试约束，但被 Brakeman 忽略的 8 项仍保留为历史排除事项，不谎称“消失”。证据：D:\开发\Abroa\.p1-p4-full-20261126\logs\sure-high-ignore-security-retest-20261126T021222Z.log。
- A14 新增真实本地 OpenAI Chat Completions 端点的 500/503 上游错误模拟：HTTP 请求确实通过 Net::HTTP 发出，合成凭证不会出现在 ModelFailure 信息中；现含 401/500/503、302 metadata 重定向、坏 JSON、token 截断。8 runs / 75 assertions / 0 failures；提交 7cc66fec92b1d786c2f7e44ac38118e15c0eefc1。
- A12 本地 SMTP 服务器真实接收通知，验证无金融明细/项目名称泄露，重复 Job 不产生第二封，Sure Entry 未变化；SMTP_REAL_LOCAL_EXIT=0。此项为本地协议模拟，不等于真实外部邮箱服务器投递。
- P3→P4 原有 39 张财务/业务表的相同主键行哈希匹配；用户敏感字段需按本轮安全加密 backfill 迁移语义分别核实，不将预期加密更新错误视为数据损坏。
