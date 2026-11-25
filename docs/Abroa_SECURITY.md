# Abroa 权限和安全规格 v1.0
采用 A 为主：保留 Sure 已有安全体系，只补新增领域与确实存在的缺口。当前静态证据：users.family_id、accounts.family_id/owner_id、account_shares、budget_shares、sessions、api_keys、oidc_identities、security_audit_logs、impersonation_sessions。已有能力的完整性需 P0 测试，不另建身份平台。
## 1. 授权模型
|角色|自身财务|他人汇总|他人明细|提出计划|直接编辑他人计划|系统运营|
|---|---|---|---|---|---|---|
|学生|原有权限内|默认无|无|自身及协作|自身|无|
|未绑定家长|自己的空间及草稿|无|无|仅草稿|无|无|
|已绑定家长|自己的空间|显式 grant|默认无；指定明细 grant|相关项目及 propose 权限|指定 manage grant|无|
|平台管理员|个人空间同普通用户|无|无|无额外权限|无|指定运营权限|
关系本身不授予读明细；grant capability 分开 summary, account_balance, transaction_details, budget_read, fees_read, forecasts_read, propose, budget_manage, fees_manage, pool_manage。资源 scope=project/明确 resource，禁止通配扩大隐私。家长拨款自身记录可见，但到账匹配的银行明细必须额外授权。不能将 family admin 当平台 admin 或家长；不得通过原邀请加入学生 family 获取全部权限。已存在 Sure 家庭共享继续按原边界；新增独立注册默认私有。
## 2. 执行规则
鉴权->actor->授权 scope->资源查询->具体操作 capability->事务内版本再校验。所有路径包括 API、原 Web controller、导出、缓存、后台 jobs、AI tools、通知、文件下载。禁止先全局 find 再过滤或仅依赖传入 family_id。跨租户 parent 查询使用专门授权投影，序列化白名单（不能暴露 notes、merchant、账户号、raw imports、明细 IDs 等）。小范围聚合/筛选不得用来反推被隐藏交易；仅允许已授权维度、固定时间粒度，限制任意组合过滤。撤销即时递增 grant version，缓存失效，排队任务、导出下载与邮件发送重新检查。不可收回已合法下载数据，告知用户。
## 3. 安全控制
- 复用邮箱验证、Google/OIDC、session、API key、OTP/Passkey 等实际机制。Google 验证 issuer/audience/signature/nonce/state/subject；账号关联需已验证身份和明确确认，token 不写日志。
- 按原 Active Record encryption 和配置保护 bank/AI secret；仅写入、脱敏返回；密钥不得进入 git、诊断、测试 fixture、AI prompt。新用户/旧实例密钥升级按原文档处理。
- 自定义 API URL：云端只允许 http(s) 中符合 HTTPS 政策的端点，拒绝环回/私网/link-local/metadata、DNS rebinding 及重定向绕过；限制超时、响应大小、并发。自托管显式允许本地模型，由部署者配置，不向云端开放内网。
- 导入验证类型/大小/编码、解压膨胀、恶意公式及路径；文件私有、授权下载，CSV 导出防公式注入；模型提取仅解析数据，禁止将文件文本当高权限指令。
- 管理员默认不能读账务；核查并限制既有 impersonation 路径在 Abroa 云端的使用；必须经独立权限、明确支持目的与审计才能进行任何必要的例外访问，不能为普通运营开后门。
- 审计追加记录 actor、tenant、resource、operation、request_id、安全 diff、时间；禁止存原始凭证及不必要明细；权限修改、AI 写操作、核销、导入回滚、管理员敏感操作必审计。
- 账户删除/导出遵守原生命周期并扩展项目/家长权限/任务/缓存/原始文件；删除范围及需保留的协作记录按实际政策核实，不承诺法定合规已认证。
## 4. 验收攻击面
IDOR（读写、列表、批量、导出、附件）、跨 family scope、平台管理员误权、授权撤销与并发执行、过期/重用邀请、权限提升、缓存串租户、邮件/日志泄露、AI prompt injection/工具越权、SSRF、恶意文件、重复入账、并发超分配、token 重放。使用学生 A/B、家长 P/Q、管理员 M 多租户 fixture 测试；负向必须断言无数据修改和无敏感内容。P0 记录现有漏洞或基线失败，不绕过。

## P3 跨租户安全边界（2026-11-25）

默认拒绝：关系仅证明学生与家长关联，不共享 Sure 家庭；原 `Current.family`、`AccountPolicy`、`StudyProject.for_user` 不因关系而放宽。家长访问学生项目必须从有效 `Grant.scoped_to_parent` 获取，联合验证家长 user/family、relation active、student user/family、project owner/family、Grant capability/resource/expiry；未授权 API 返回 404，避免跨项目资源枚举。授权立即撤销并同时禁用关系内活动 Grant。家长独立草稿只在家长家庭创建。

资金安全：拨款计划、草稿、预算、汇款声明均不写 Sure 原始账本；学生本人以独立 `EntryAllocation.locked_entry!` 校验 `Entry`，完成凭证、币种、账户归属和入账状态核验，写入独立唯一匹配记录。冲正引用真实退款流水，不直接调整原账本。父母端默认隐藏学生银行账户 ID、支付对象、流水详情；额外授权才可返回裁剪后的交易投影。父母账户 ID 不出现在学生端。

并发及审计：所有资金匹配、提议审批和授权撤销记录真实操作者与不可变操作历史；重要状态机使用行锁、`lock_version`、PostgreSQL 唯一索引和幂等请求摘要。跨币种历史匹配持久化 RateSnapshot；核对原始流水后若源账务发生漂移，汇总拒绝输出看似可信的金额。待办关联、预算、拨款的全业务执行必须在有效权限之下，不能仅检查对象 ID 或原 Family 权限。


## P4.1 应收应付安全边界（2026-11-25）

用户只可读取本人的 `family_id + owner_id` 债务；账户/Entry 权限通过 Sure `AccountPolicy` 与 P3 `EntryAllocation.locked_entry!` 实时校验；写入使用 `StudyProject.with_actor`、事务、行锁、唯一约束和 `lock_version`，防止重复结算与竞争。不能调用直接更新 Cash Account.balance；创建的 Sure `OtherAsset` 和 `OtherLiability` 不是现金账户。净消费仅在统计投影中剔除他人承担部分、重复偿还和借款流入。

`RateSnapshot` 固化历史 FX，缺失或错误汇率拒绝核销；源商户退款必须引用 P1 `RefundLink`，以不可复用的退款 Entry 和比例上限防止重复退回。失效源交易/链接被检测为 inconsistent，拒绝继续结算。Idempotency-Key 哈希与请求内容绑定。审计记录只保存必要的非私密金额/标识，不包含联系人和凭证。父母不能从当前个人债务 API 获得他人应收应付（未开放个人债务 Grant）。

真实并发、旧 Schema 升级、完整回归及 Docker 独立预生产结果必须以 `docs/P4_BACKEND_ACCEPTANCE.md` 实际日志为准；未经全部验收不得宣称安全保证已获最终认证。

## P4.2 A11 forecast authorization and calculation safety

Forecast is read-only, deterministic and BigDecimal-based. Student cash account IDs must be accessible and owned, project-linked when project-scoped; inaccessible IDs return 404. It cannot write Entry, balance, transaction or real payment. Input date, scenario, historical FX, amounts, multipliers, delays and finite values are validated before returning numeric results. Zero-history, missing-rates and inconsistent settlement evidence are surfaced explicitly rather than misrepresented as exact financial predictions.

Parent forecast requires an active student-parent relation plus effective project summary/forecasts_read/account_balance/fees_read grants at request time. It removes account identifiers, individual transactions, private debt assumptions, anomaly flags and other parents' unreceived funding plans. It does not persist or reuse parent-specific cached financial data; a withdrawn grant therefore blocks the next request. Scope-specific data-version fingerprints avoid revealing unrelated project edits through cache metadata.

## P4.3 A12 通知与邮件安全

站内通知的唯一 ID、事件键不可用作他人数据访问凭证；收件人必须为当前登录的用户且 family 匹配。查询和已读再次检测源资源（P3 Grant/关系撤销后失去详情权限）；邮件 Worker 执行前重新读取用户、偏好和源权限，拒绝错配 recipient/family/source、跨租户与已撤销授权。邮件正文和主题完全通用，不包含姓名、银行账户、项目、交易、金额、API Key、原始导入文本；收到邮件时仍须在 Abroa 登录后访问收件箱。邮件默认 opt-out；静默时段按用户 timezone 处理。

Outbox 在 PG 事务锁中独占标记 sending；已发出不重复发送；Worker 重启时弃置不确定的旧 sending 为 uncertain（需要人工核实 SMTP 接收情况），明确拒绝的 SMTP 响应才进入安全重试 failed。记录错误类别，不回显 SMTP 响应正文或凭证。真实第三方 SMTP 验证列为外部缺口；本地投递器/真实隔离 PG、Sidekiq 模拟任务属于可执行验收。
