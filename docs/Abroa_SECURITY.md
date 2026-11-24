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
