# P0.4 源码对照与首批实施契约

基线：fc576847dcb2b33ad9ef8a9003356978fcaa4ce5；当前 schema 2026_11_23_220100，迁移类使用 ActiveRecord::Migration[8.1]。静态检索未发现现有 Abroa namespace 或 abroa_ 表；新领域采用 Abroa:: 命名空间和 abroa_ 表，不重命名 Sure 表。

## 原版边界与兼容性

| 原版证据 | 实施决定 |
|---|---|
| users.family_id 必填；accounts.owner_id 可空；AccountPolicy#permits? 区分 owner/full_control/annotate | 现有财务资源仍采用 family 与账户授权；新增家长关系不改变原用户 role、family 或账户共享 |
| RegistrationsController#create、OidcAccountsController#create_user 可加入原版 family 邀请，未邀请时新建 family | 原版邀请保留；Abroa 家长邀请独立建模，不可复用加入 family 的路径 |
| Oidc::ProviderOptionsBuilder 使用 discovery、PKCE、openid email profile；SessionsController#openid_connect 按 provider + uid 找身份 | Google 复用 OmniAuth/OIDC，不重新造认证；特定 Google 路径必须校验 issuer/subject 和已验证邮箱 |
| Web pending_oidc_auth 当前仅保存 provider/uid/email/name；OidcIdentity issuer 可空兼容历史 | Google 新身份需安全保存经过验证的 issuer 与 email_verified；已有关联身份仍按现有 provider/uid 查找但验证 issuer；不允许仅邮箱自动合并，不改变其他 IdP 历史兼容 |
| budgets 现有 shared/personal 两个部分唯一索引；Budget.period_for 为月周期 | 任意留学预算独立 abroa_budget_nodes，避免破坏现有月度索引与数据 |
| entries.amount decimal(19,4)；accounts.balance decimal(19,4)；goal_accounts.allocated_amount decimal(19,4)；recurring_allocations.source_amount/currency 已存在 | 金额沿用定点精度；新分配、核销与 Goal/Recurring 保持统一锁和真实 Entry |
| config/routes.rb 已有 api/v1 auth、accounts、transactions、budgets、imports、recurring、chats | 在 api/v1 内新增 abroa namespace；不改变现有路由、OAuth、API key 或原响应格式 |
| BaseController 的原版错误为 error/message/errors，分页 page/per_page；Abroa PRD 指定 cursor 与嵌套 error | 仅在 Api::V1::Abroa::BaseController 适配新契约；旧接口行为完全不变 |
| Assistant::FunctionToolCaller#execute 直接 fn.call；订阅控制器禁止 self-hosted checkout | 聊天写确认需在统一分派边界实施，不能只限制新工具；套餐权益不触发 Stripe |

## P1.1 首批数据契约

- Abroa::Profile（abroa_profiles）：UUID、user_id 非空唯一 FK、student_enabled/parent_enabled 默认 false、origin_country/residence_country 可空、display_currency/timezone 可空、mode 默认 simple、onboarding_step 默认 role、completed_at 可空、lock_version 默认 0、timestamps。
- Profile 是用户自身的偏好而非财务事实，user_id 为唯一所有权依据；family 从用户关联派生，不重复持久化可因原版用户迁移而失效的 family_id。其他财务租户表仍按原数据库规格保留 family_id 与资源约束。此处是 Abroa_DATABASE 的明确例外。
- 新用户无需先创建项目；两种角色可同时开启；不通过原版 admin/super_admin 映射。原用户没有 profile 时返回默认值，不自动创建数据或改变现有 UI。
- 模式允许 simple/professional/custom；地区、币种及时区使用项目现有可验证的地区/货币/时区代码；不合法输入 422，不能客户端写 user_id 或 family_id。
- 引导由用户自己选择或跳过非必要步骤，重复请求无重复数据；完成时间和版本锁只在真实成功写入后更新。

## P1.1 API 契约

路径前缀 /api/v1/abroa。认证继承原 API BaseController（OAuth 及 X-Api-Key）；使用 Current.user/Current.family。GET 不产生数据库写入；PATCH 仅允许本人字段，验证版本；不存在 profile 时首次创建在唯一约束下安全重试。保留原 API 的 read/read_write scope、active 状态及 guest 写限制。

| 方法/路径 | 请求与响应 |
|---|---|
| GET /profile | 200 data: profile 默认值或已持久化数据，不返回他人 ID |
| PATCH /profile | role bool、地区、币种、时区、mode、lock_version；200 更新版本，409 旧版本，422 非法输入 |
| GET /onboarding | 200 data: step、completed_at、lock_version |
| PATCH /onboarding | step、lock_version；只允许已定义流程/合法跳过，200 |
| POST /onboarding/complete | Idempotency-Key、lock_version；200，重复完成回放；无需创建项目 |

响应 decimal string 等共用约定见 Abroa_API。新增端点的 Minitest + documentation-only rswag schema 在 P1.1 与真实实现同批完成，随后生成 docs/api/openapi.yaml；P0 不伪造已存在的端点或覆盖原文档。

## 外部接入与未完事项

支付宝、微信使用合成账单 fixture 验证首批逻辑，真实格式版本需经脱敏样例确认；国内银行名单不能在缺少样例的情况下声称已支持。Google OAuth 客户端、真实金融服务及模型凭证仅在外部验收阶段使用；不自行改写真实凭证。其他 P1–P5 表字段、资源锁及 OpenAPI 精确 schemas 仍须按实际方法审计和对应任务细化。本记录是 P0.4 部分交付，未标记该阶段完成。
