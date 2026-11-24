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
