# Abroa REST API 规格 v1.0
拟新增 /api/v1/abroa；沿用 API v1 BaseController、X-Api-Key 及既有 session/OAuth 机制（实际支持由 P0 核实）。既有 API 不破坏；新增路径对应 Minitest 行为覆盖和 documentation-only rswag、更新 docs/api/openapi.yaml。以下为接口契约，不代表已存在路由。
## 通用约定
JSON；UUID string、金额/汇率 decimal string、日期 YYYY-MM-DD、时间 ISO8601 UTC、currency ISO/原系统支持代码；分页 limit 默认 25 最大 100，cursor 不透明，稳定排序 created_at/id；列表以 data 和 meta.next_cursor 返回（兼容既有 API 包装由 P0 确定）。写请求 Idempotency-Key（创建、核销、导入、确认、撤销必需）；同 actor+operation+key 同请求回放原结果，不同 body 409。修改需 lock_version 或 If-Match。错误为 {error:{code,message,field_errors?,request_id}}；400 malformed、401 未认证、403 禁止、404 不可见资源、409 冲突/版本/重复、422 业务校验、429 限额、503 依赖不可用；不泄漏跨租户存在性。异步返回 202 + job/status URL，状态可查询。不通过客户端传 family_id 授权。
## 端点矩阵
表中路径均为前缀下；CRUD 指 GET list/detail、POST、PATCH；DELETE 仅用于安全可删草稿，否则显式 archive/cancel/revoke。所有 detail 操作须 actor scope。
|路径|方法/操作|主要请求/返回|
|---|---|---|
|/profile, /onboarding|GET/PATCH; POST complete|角色模式、地区、币种、当前步；完成状态|
|/projects|CRUD; POST /:id/archive, /restore|name,country,city,school,start_on,end_on,currency；状态|
|/projects/:id/periods|CRUD|parent_id,kind,start_on,end_on|
|/projects/:id/accounts|GET/POST/DELETE :account_id|account_id；只关联资金来源|
|/projects/:id/allocations|GET/POST/PATCH :id/DELETE :id|entry_id,amount,currency,category_id；未分配额|
|/projects/:id/summary|GET|as_of,currency,from,to；分类、费用、资金、缺失汇率|
|/relationships|GET/POST invite; POST /:id/accept,/revoke|recipient,token；双向状态|
|/relationships/:id/grants|GET/POST/PATCH :id; POST /:id/revoke|project/resource scope,capabilities,expires_at|
|/parent/drafts|CRUD; POST /:id/propose|规划 payload；接受后目标 project|
|/proposals|GET/POST; POST /:id/accept,/reject,/cancel|operation,resource,patch,expected_version；状态、执行结果|
|/parent/students/:id/summary|GET|project_id,currency,from,to；仅授权字段|
|/sources|GET|类型、地区、capabilities、可用状态|
|/imports|POST multipart; GET /:id; POST /:id/preview,/publish,/revert|file,source_kind,account_hint,template；批次结果|
|/reviews|GET; POST /:id/resolve|resolution link/create/ignore/classify/split/dismiss, target_id?,expected_version|
|/refund-links|POST; DELETE :id|original_entry_id,refund_entry_id,amount|
|/fx|GET rates; POST /exchanges; GET/PATCH /exchanges/:id|transfer_id,实际两腿/fee、成交汇率|
|/projects/:id/budgets|CRUD; GET /:id/execution; POST /:id/adjust,/rollover|period,parent,category,currency,limit,threshold；actual,committed,available|
|/projects/:id/pools|CRUD; POST /:id/movements|account_id,kind,amount,currency；allocated/reserved/available/shortfall|
|/projects/:id/funding-plans|CRUD; POST /:id/propose,/confirm,/cancel,/matches|expected_amount,currency,due_on,pool；entry_id,applied_amount；到账差额|
|/projects/:id/fees|CRUD; POST /:id/adjustments,/installments,/cancel|gross,kind,deadline,recurrence；net_due|
|/fee-installments/:id/payments|GET/POST; POST /:payment_id/reverse|entry_id,amount,currency,kind；paid/open/overdue|
|/projects/:id/forecast|GET; POST /recalculate|as_of,horizon 30/90/180,currency,scenario_id；cashflow,runway,shortfall,assumptions|
|/projects/:id/scenarios|CRUD|bounded assumptions；不写实际账务|
|/receivables|CRUD; POST /:id/settlements,/cancel|direction,counterparty,original_entry_id,share,amount；outstanding|
|/reports|GET /project,/funding,/fx,/fees; POST /exports|period,currency,project；导出异步、再次鉴权|
|/notifications|GET; POST /:id/read,/read-all; PATCH /preferences|收件箱、渠道偏好|
|/ai/config|GET/PATCH; POST /test|api_url,api_key write-only,model；仅掩码|
|/ai/actions|GET/POST; POST /:id/confirm,/reject,/undo|action_kind,resource,payload,version；diff、expiry、confirm token|
|/admin/users|GET; POST /:id/suspend,/restore|账号状态；不返回财务明细|
|/admin/plans,/entitlements|CRUD|配置、feature、quota；价格未定不启用实际收费|
|/admin/usage,/providers,/imports,/health,/audit|GET; PATCH 有权限的配置|脱敏聚合、状态、权限审计|
|/admin/regions|CRUD|地区配置、模板|
## 示例
POST /projects/{id}/funding-plans: {"expected_amount":"1000.00","currency":"GBP","due_on":"2027-01-01","pool_id":"<uuid>"} -> 201 {"data":{"id":"<uuid>","status":"planned","expected_amount":"1000.00","received_amount":"0.00","currency":"GBP","lock_version":0}}；不创建银行交易。
POST /reviews/{id}/resolve: {"resolution":"link","target_entry_id":"<uuid>","expected_version":2} -> 200 原 entry 仍唯一，source_record 链接更新。目标越权 404，匹配证据不足 422，版本冲突 409。
POST /ai/actions/{id}/confirm: {"confirmation_token":"<single-use>","expected_version":3} -> 已校验的命令结果；无 token 或过期不得执行；不接受客户端替换已确认 payload。
## 实施
P0 核实 API 路由、controller、认证方式及现有 serializer，再将精确 OpenAPI schemas/status/security 定稿。每端点至少授权正例、未认证、他人 ID、错误输入、并发/幂等（写）测试。新接口前端未开发不影响 API 验收。

## P3 家长—学生跨租户协作与拨款 API（2026-11-25）

所有路径均以 `/api/v1/abroa` 为前缀；认证遵循 Sure 的 `X-Api-Key` / 会话机制。写请求必须具备 write scope。创建邀请、授权、草稿、提议、拨款计划、到账匹配、冲正和建议时要求 `Idempotency-Key`；状态变更须提供整数 `lock_version`。列表遵循 `limit` / `cursor`，响应保留 `data` / `meta.next_cursor`。对未授权资源返回 404，对重复/过期/版本冲突返回 409。

| 方法 | 路径 | 权限和用途 |
|---|---|---|
| GET/POST | `/relationship_invites` | 本人邀请列表／创建仅关联本人身份的邀请；创建返回一次性邀请 token |
| GET/DELETE | `/relationship_invites/{id}` | 仅邀请双方查看／发起人撤销未处理邀请 |
| POST | `/relationship_invites/accept`、`/relationship_invites/reject` | 被邀请邮箱对应的真实用户接受／拒绝；请求体为 `token` |
| GET | `/relationships`、`/relationships/{id}` | 本人参与的家长—学生关系 |
| POST | `/relationships/{id}/revoke` | 关系参与者撤销；所有活动 Grant 同事务撤销 |
| GET/POST | `/relationships/{relationship_id}/grants` | 关系双方读取有效授权；仅学生创建授权 |
| DELETE | `/relationships/{relationship_id}/grants/{id}` | 仅学生撤销指定授权 |
| GET/POST | `/parent/drafts` | 家长个人独立预算、留学项目、资金规划草稿 |
| GET/PATCH/DELETE | `/parent/drafts/{id}` | 家长本人查看、按版本修改、取消未提交草稿 |
| GET/POST | `/proposals` | 授权内的预算创建、预算修改及留学项目变更提议 |
| GET | `/proposals/{id}` | 家长本人（有效 propose 授权）或学生查看 |
| POST | `/proposals/{id}/submit`、`/cancel` | 家长提交或取消；须保持有效授权 |
| POST | `/proposals/{id}/accept`、`/reject` | 学生审批；接受时原子应用并记录 `applied_resource_id` |
| PATCH | `/parent/budgets/{id}` | 持指定 `budget_manage` Grant 的家长直接修改指定预算 |
| GET/POST | `/funding_plans` | 家长创建拨款计划；关联双方读取各自可见计划 |
| GET/PATCH | `/funding_plans/{id}` | 按角色查看；家长修改尚未确认的计划 |
| POST | `/funding_plans/{id}/confirm`、`/reject` | 学生确认收款账户、绑定资金池或拒绝 |
| POST | `/funding_plans/{id}/cancel` | 关系参与者取消，不删除历史到账 |
| GET/POST | `/funding_plans/{funding_plan_id}/receipts` | 学生把真实已入账 Entry 唯一匹配至拨款，支持不同期和多次到账 |
| GET | `/funding_plans/{funding_plan_id}/receipts/{id}` | 学生详细账务；家长须额外有 `transaction_details` 授权才读受限投影 |
| GET/POST | `/funding_plans/{funding_plan_id}/notices` | 家长汇款声明，仅待匹配，不形成余额 |
| POST | `/funding_plans/{funding_plan_id}/notices/{id}/revoke` | 家长撤回未证实的汇款声明 |
| GET/POST | `/funding_receipts/{funding_receipt_id}/reversals` | 学生引用真实退款 Entry 冲正原始到账，保留原汇率 |
| GET/POST | `/funding_plans/{funding_plan_id}/suggestions` | 学生提出拨款金额/日期等调整建议；关联双方可查看 |
| POST | `/funding_plans/{funding_plan_id}/suggestions/{id}/accept`、`/reject` | 家长按版本确认/拒绝学生调整建议 |
| POST | `/funding_plans/{funding_plan_id}/suggestions/{id}/cancel` | 学生取消待处理建议 |
| GET | `/parent/projects` | 家长拥有有效 `summary` Grant 的项目列表 |
| GET | `/parent/projects/{id}/summary` | 仅授权项目的消费、费用、拨款、预算等受限聚合 |
| GET | `/parent/projects/{id}/budgets`、`/fees`、`/pools` | 附加相应授权后返回经过裁剪的资源投影 |
| GET | `/parent/projects/{id}/expenses`、`/funding` | 交易详情须 `transaction_details` 授权；拨款仅查看本人对应的计划 |

授权对象有 `resource_kind=project|budget_node|fee_plan|fund_pool`、`resource_id`、`capability`、`expires_at`。可用 capability：`summary`、`account_balance`、`transaction_details`、`budget_read`、`fees_read`、`forecasts_read`、`propose`、`budget_manage`、`fees_manage`、`pool_manage`。`resource_kind=project` 时 `resource_id` 必须为空；指定对象时必须属于该学生的项目。任何关系的建立**不授予**这些权限。家长未获授权的字段、银行账户 ID、流水、其他项目均不得通过投影泄露；不能修改 Sure 家庭作用域。

提议 `operation` 可为 `budget_create`、`budget_update`、`study_project_update`。预算直接编辑仅接受 `name`、`limit_amount`、`warning_threshold` 三个安全字段。提议生命周期：`draft → pending → accepted/rejected`，或尚未结束时 `cancelled`；审批时重新校验有效 Grant、关系、目标版本、预算周期及项目边界。接受创建预算返回 `applied_resource_id`。家庭与账户不会因家长草稿自动合并。

拨款 `frequency` 支持 `once`、`weekly`、`monthly`、`quarterly`、`yearly`，一次计划最多 120 期。仅引用学生家庭真实已入账、非 pending 的 Sure `Entry`，同一到账 Entry 有全局唯一索引防止二次匹配。拨款状态 `planned → confirmed → partially_received → received`，允许合法的 `rejected/cancelled`。家长汇款通知不是实际到账。历史外汇金额由匹配时保存的 `RateSnapshot` 固定；退款必须匹配真实流出 Entry，在原收款的历史价值上反向记账，且不修改原 Entry 或余额。已匹配的原始账务发生变化时，相关汇总标记 `incomplete`，不再声称金额可信。学生的建议由家长审核，通过之前不会修改拨款计划；已有真实到账时禁止通过建议更改历史币种或计费周期。

验证入口：Minitest `test/models/abroa/{relationship,parent_planning,funding_plan,parent_overview,p3_concurrency}_test.rb` 以及对应 controller tests；rswag 文档专用规范 `spec/requests/api/v1/abroa/p3_parent_spec.rb`。完整验收结果与风险以 `docs/P3_BACKEND_ACCEPTANCE.md` 为准。


## P4.1 个人应收应付 API（A10，开发验收中）

所有路径以 `/api/v1/abroa` 为前缀，API Key 按 Sure 的认证与 read/read_write scope 执行，IDOR 返回 404。请求必须发送 `Content-Type: application/json`，写入请求还应传稳定的 `Idempotency-Key`；分页使用 `limit` / `cursor`。

| 请求 | 路由 | 行为 |
|---|---|---|
| GET | `/personal_debts` | 仅本人债务，支持 `status`、`direction` 过滤 |
| POST | `/personal_debts` | 创建有 Sure 账务证据的个人应收/应付，`kind=paid_for_other/paid_by_other/lent/borrowed` |
| GET | `/personal_debts/{id}` | 本人详情、剩余本金、状态、债务关联账户 |
| POST | `/personal_debts/{id}/cancel` | `lock_version` 乐观并发校验，已结算拒绝取消 |
| GET | `/personal_debts/{id}/settlements` | 仅本人结算列表 |
| POST | `/personal_debts/{id}/settlements` | `kind=payment` 结算；`kind=refund` 返还已核销款并引用 `refunded_settlement_id`；`kind=source_refund` 关联 Sure `refund_link_id` 记账消减原始代付债权 |

`POST /personal_debts` 常用字段为 `kind, contact_nickname, purpose, source_entry_id, currency, personal_amount, other_amount, incurred_on, due_on, project_id`。源交易必须是真实已入账、可见、方向和金额正确的 Sure Entry；`paid_by_other` 记录个人尚未支付而形成的应付款，可无源 Entry。结算需要引用已经存在的真实现金 `entry_id`、该交易原币金额 `amount`，同币种不需要新增汇率；跨币种使用 Entry 发生日的历史汇率快照。`source_refund` 必须先存在有效的 P1 Sure RefundLink，不直接修改余额。写入返回 201，重复请求同参数返回原对象；错误参数 422、状态/版本冲突 409、无权 404、凭证缺失 401/403。

`OtherAsset` / `OtherLiability` 表示应收应付的非现金权益；其 Valuation Entry 不是银行存款和个人消费。P4.1 验收文件：`docs/P4_BACKEND_ACCEPTANCE.md`；详细行为定义见 `app/models/abroa/personal_debt.rb`、`debt_settlement.rb`。该阶段仍处于联合验收前，不能称为 P4 完成。

## P4.2 A11 deterministic forecast endpoints

- `GET /api/v1/abroa/forecasts`: authenticated student finance forecast. Optional `project_id`, `currency`, `account_ids[]`, `scenario` (`conservative`, `planned_funding`, `stress`), `living_multiplier`, `rent_multiplier`, `fx_shock_pct` (0..1), `funding_delay_days` (0..180), and `timeline=true|false`.
- `GET /api/v1/abroa/parent/projects/{id}/forecast`: parent aggregate projection after active relationship and project `summary`, `forecasts_read`, `account_balance`, `fees_read` grants. The parent cannot select arbitrary student account IDs or view private debt, transaction-level details or abnormal-spend flags. Revocation is checked on every request.
- Values: algorithm and input versions, UTC data timestamp, currency and scenario; day 10/30/90/180 balances, daily historical baseline, first shortage date, shortage amount, runway days, future hypothetical income, reserve warning, 30-day top-up estimate, expected cost to 180 days, and project total/remaining cost estimates. `missing` and `incomplete` report absent historical FX or sources; never substitute missing financial data with a manufactured 0.
- Conservative and stress scenarios exclude unreceived planned transfers from actual cash; `planned_funding` assumes explicit hypothetical arrivals. No forecast endpoint modifies Sure Ledger, bank balance, actual funding receipts or fee settlements. Cost estimates extrapolate historical daily living spend and add separately identified P2 fee obligations.
- Input errors return 422, inaccessible account or grant 404, unauthorized 401. Documented in `spec/requests/api/v1/abroa/p4_forecasts_spec.rb` and generated `docs/api/openapi.yaml`.
