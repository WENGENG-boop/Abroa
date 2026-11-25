# P4 代码审查记录（滚动）

审查基线：`c755b002f`，变更位于 `abroa/development`。本记录不是 P4 总体验收签字。

## P4.1 A10

账务：使用真实 Sure Entry 作为现金证据、`OtherAsset` / `OtherLiability` 账户与 Valuation 表示债务，没有执行直接更新银行 Account.balance。模型金额采用 BigDecimal，历史跨币种结算使用 `RateSnapshot`。`NetConsumption` 仅在读投影中剔除他人份额及重复偿还；不修改原始分录。

权限：查询按 `owner_id` 与 `family_id` 双重限制。写操作遵循 API Key scope、`StudyProject.with_actor`、`EntryAllocation.locked_entry!` 与现有 AccountPolicy。跨租户、只读 Key、未认证请求已纳入 API 测试。联系人昵称不会出现在审计 `safe_data`。

幂等及并发：唯一索引约束用户创建 key、债务内结算 key、来源 Entry 和结算 Entry；行锁及二次实时余额校验防止超额核销；SQL 约束禁止负本金及负结算。已执行两个不同 PostgreSQL backend PID 的并发用例，分别竞争超额核销和重复幂等确认，2 tests/11 assertions，0 失败、0 错误。仍需 P1–P4 全链路压力与负向测试。

退款：客户返还部分已收偿还，须匹配独立现金 Entry 和原结算；原消费商户退款必须先通过 P1 `RefundLink`，按他人承担比例减少应收与个人消费，不能生成虚构资金流。撤销仅限无结算记录的债务，历史记录保留。

发现并已修正：
1. 初版将流入 Entry 的负数用于正值校验，导致结算验证失败；改为记录绝对值，测试复验。
2. 原始商户退款与他人承担比例未联动；添加独立迁移及 `source_refund` 账务匹配，并补充回归。
3. 测试 fixtures 的 800 GBP 消费未建立相应债权时，误将该笔消费视为别人承担；补齐确实需要的债权测试前置数据，未降低断言。

检查结果（以执行日志为准）：A10 11 tests / 74 assertions 全通过；RuboCop 10 文件 0 offense；API consistency 通过；一次 Brakeman 全库扫描 0 active warning。数据库两条新增迁移的 down/up 往返验证通过，日志见 `20261125T062520Z-346747.log`。完整 Rails 回归、P3 有历史数据升级、Docker stage 仍缺最终证据。

## P4.2 / A11 预测引擎审查（阶段进行中）
- 确定性 BigDecimal 财务推算，不含模型数值计算及实际账务写入。输入参数在数据不完整返回前校验，避免非法情景意外获 200。
- 实际可用现金仅包括本人获授权的 Sure Depository；项目仅选择已关联的账户。个人应收及尚未到账的计划拨款不进入真实现金；计划拨款仅在假设情景入账。
- 历史固定费用从日常消费基线剔除，分期和债务只使用未清偿部分；FX 缺失标记 incomplete，不得回退为原币数值混加。
- 家长预测需要当前有效的关系及 summary、forecasts_read、account_balance、fees_read Grant，排除私密债务/异常消费明细及其他家长计划，且不缓存授权快照。查验单独 API 越权与授权撤销测试通过。
- A10–A11 扩大回归 288/1788 全通过；RuboCop 5 文件 0 违规；Brakeman 0 活跃警告；OpenAPI 已生成。最终 P1–P4 联合安全审查仍待签收。

## P4.3 / A12 站内与邮件审查（阶段进行中）
- 所有 Inbox 和 Outbox 行带 recipient/family，索引对收件人+事件键作唯一约束；不使用用户提供的类名动态取模型。读取通知和发送邮件均检查动态资源授权，读接口不返回源资源、金额、银行或导入内容。
- 通知偏好邮件默认关闭，可设置 IANA 时区静默时段；偏好写入有 lock_version 与 read_write scope；未知字段拒绝。错误收件人/跨租户、家长授权撤销、重复 Worker 及恢复均有负向测试。
- `pending/failed -> sending` 以 PG 行锁唯一认领，SMTP 明确拒绝才安全延迟重试；网络异常/Worker 中断因接收状态未知而列为 uncertain，不做可能重复的自动发件。
- 复用 P2 费用提醒、P3 授权/拨款及 Sure 交易同步事件，不自行创建财务 Entry。Cron 通过现有 Sidekiq 队列。
- 现有证据：A12 单元/API 17/88、双 PostgreSQL 并发 2/8、迁移 down/up、Abroa 扩大回归 307/1884、RuboCop 14/0、Brakeman 0 活跃警告、OpenAPI 630/0 全通过；真实 SMTP 和 Docker Worker 级验收尚需最后联合执行。

## P4.4 / A13 财务报表与导出审查（阶段进行中）
- 权威财务事实来自原 Sure Entry/IncomeStatement 与 P2 ProjectSummary；P4 是只读调整投影，不写第二套 Ledger，不把未到账拨款/资金池目标视为现金。独立 `ProjectDebtRecognition` 在已有项目分配中消除第三方本金、商户退款与还款对个人消费的重复影响。历史 FX 缺失返回 incomplete 和 null，不做原币叠加。
- 学生仅可选择自身已授权、与项目绑定的账户/学年学期。家长只可指定完整自然月或预定义学年学期；禁任意账户及窄时间过滤，少于 5 笔 P2 独立 Entry 的支出结果隐藏，其他字段再按有效 Grant 细分。
- 文件仅以受控 ID 传递，不暴露 ActiveStorage signed ID；每次下载按 owner/family、有效期、当前 project/Grant/账号可读、字节 SHA-256 校验，记录审计。家长 Grant 摘要绑定创建时授权集，任何撤销/变更阻止旧文件下载和同 key 重放。CSV 所有单元格处理公式触发字符。
- Minitest 12/91 全通过；A10–A13 扩大回归 319/1975 全通过；RuboCop 8/0，rswag 634 examples/0 failures，数据库迁移 down/up 0。最终联合安全审查及 Docker 预生产待验收。

## P4.5 / A14 AI 财务助手代码审查（阶段进行中）
- Provider 单用户唯一、family ACL、Rails ActiveRecord encrypts、所有 JSON 与 inspect 均遮罩 API Key；`config/initializers/filter_parameter_logging.rb` 已有 `:_key`/`:token` 过滤。公网 endpoint 只接受 HTTPS 规范 DNS host，全量 IP 检查公私网、请求 IP pin/证书验证、禁止代理与 3xx，防 DNS rebinding、metadata SSRF。仅 self_hosted 且由管理员显式精确白名单启用本地 IPv4 模型。
- 模型只能获取授权后的报告/预算数据和明确标为不可信的导入文本，不能发起代码执行、SQL、支付或任意交易写入。家长只有 summary Grant 的小样本抑制聚合，Grant 撤销后请求拒绝；模型异常仅返回泛化错误、保留已有财务功能。
- Sure AI 工具清单在 Abroa role 下剔除写工具，MCP 取同一清单；FunctionToolCaller 对注入的写工具对象二次拒绝。不影响其他非 Abroa Sure 用户的原有工具。
- 写操作每步独立服务端权限验证、随机 token hash/有效期/版本/状态 digest、幂等、审计和可确认的补偿；预算调用 P2 BudgetNode、费用 FeeAdjustment、资金池 PoolMovement，未实现类别和导入匹配写入口。资金池先获取 Goal advisory lock 再获取 family 锁避免反向死锁。
- 专项 21/159、双 PostgreSQL 会话并发 1/7、Abroa+Sure AI/MCP 扩大回归 432/2814、RuboCop 14/0、Brakeman 240 controllers / 888 models / 0 活跃警告、rswag 646/0 已通过。第三方真模型连通性、原版 Rails 全量和完整 Docker 端到端不在这些阶段测试所覆盖范围。

## P1–P4 最终审查
尚未签收，状态：**OPEN**。
