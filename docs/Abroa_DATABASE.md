# Abroa 数据库设计 v1.0（拟定迁移规格）
基于 db/schema.rb 静态核查。现有 UUID、decimal(19,4) 与 Rails 版本保持一致。所有新增表采用 abroa_ 前缀（或经 P0 确认的等效命名），UUID PK、created_at/updated_at，必填默认 NOT NULL；以下 ? 表示可空。金额 decimal(19,4)，汇率 decimal(30,16)，currency 为受支持代码，金额有限值，正值字段 CHECK >0；显示按币种精度舍入。所有关联有 FK 和索引，租户字段 family_id 必填（平台配置除外），跨租户关系明确列出双方 ID。禁止直接改历史 migration 或手写 schema.rb。
## 1. 现有表复用与最小扩展
|现有实体|用途/扩展|
|---|---|
|users/families|身份、locale、family 默认 currency、现有 preferences；角色不覆盖原 role|
|accounts/entries/transactions|真实账务；账户地区可用扩展 profile；交易渠道使用 transactions.extra["abroa"]["payment_channel"]，保留其他 JSON；索引按实际过滤需求|
|entries|已有 account/source/external_id 唯一及 account/idempotency_key 唯一，复用；不为支付渠道再建虚假扣款|
|imports/import_rows/import_sessions/account_statements|导入及原始文件、hash、回滚，新增来源证据和 review|
|budgets/budget_categories|原月度预算、分类、滚存，保留原约束；新项目任意周期使用扩展节点，若可无破坏地统一则经 P0 决定|
|goals/goal_accounts/goal_pledges|目标、allocated_amount、matched_transaction_id；优先作为资金池承诺基座；统一锁与 Guard|
|recurring_transactions/occurrences/allocations|周期、到期、已支付核销；费用扩展关联，不复制周期引擎|
|exchange_rates|历史日汇率唯一；新快照固定报告转换|
|subscriptions/llm_usages/provider_request_counts|订阅状态和真实用量，扩展权益|
## 2. 新增实体字段
简写 ref=UUID FK，money=decimal(19,4)，rate=decimal(30,16)，date=日期，ts=UTC timestamp，str=受限字符串，json=有 schema 的 JSONB。除特别注明所有表有 family_id（所有者租户）及 timestamps。
|表（abroa_前缀）|业务字段|主要约束/索引|
|---|---|---|
|profiles|user_id ref, student_enabled bool, parent_enabled bool, origin_country?, residence_country?, display_currency?, timezone?, onboarding_step str, mode str|unique user_id；不改变 users.role|
|account_profiles|account_id ref, country?, wallet_kind?|unique account_id；账户同租户|
|study_projects|owner_id ref, name, country, city?, school?, start_on date, end_on date?, currency, status, archived_at?, lock_version int|end>=start；owner/status；归档可恢复|
|study_periods|project_id ref, parent_id? ref, kind, name, start_on,end_on|期末>=期初，父节点同项目并包含子周期，无环|
|project_accounts|project_id ref, account_id ref|unique pair；非自动交易归属|
|entry_allocations|project_id ref, entry_id ref, amount money, currency, category_id? ref|entry/project/category 唯一（null 安全）；总额<=有效 entry；父拆分只选规范化有效记录|
|relationships|student_user_id, parent_user_id, student_family_id, parent_family_id refs, status, accepted_at?, revoked_at?, version int|双方独立授权；禁止 self；活跃 pair 唯一|
|relationship_invites|relationship_id? ref, inviter_id ref, recipient_email_digest?, token_digest, expires_at, consumed_at?|token digest 唯一；单次、过期拒绝|
|grants|relationship_id ref, project_id? ref, resource_kind, resource_id? uuid, capability, status, expires_at?, revoked_at?, version|受控资源类型；明确 scope；活跃组合唯一；默认 deny|
|planning_drafts|parent_user_id ref, title, payload json, status, accepted_project_id? ref|草稿不引用他人真实账本；接受后只转化计划|
|proposals|relationship_id? ref, actor_id ref, target_kind/id, operation, payload json, expected_version, status, expires_at?, resolved_by?, resolved_at?|状态受控；确认动作幂等；不允许任意类名|
|source_records|source_kind, source_instance_key, external_id?, source_row_key, import_id? ref, statement_id? ref, account_id? ref, entry_id? ref, occurred_at?, local_date, amount money, currency, direction, status, payment_channel?, raw_digest, normalized json|稳定 ID unique(family,source_kind,instance,external_id) where present；文件行唯一；entry 索引；来源映射可多对一|
|review_items|source_record_id? ref, entry_id? ref, review_type, reason_code, candidate_ids json, evidence json, confidence?, status, resolved_by?, resolved_at?, lock_version|单活跃同类 review；状态与 actor|
|source_actions|source_record_id ref, entry_id? ref, operation, before_data json, after_data json, operation_key, reversed_at?|unique family/operation_key；回滚冲突留待处理|
|refund_links|original_entry_id ref, refund_entry_id ref, applied_amount money, currency, rate_snapshot_id? ref|unique pair；同租户，金额上限/反向|
|rate_snapshots|from_currency,to_currency,rate,rate_date,source,as_of,quality|rate>0；不可变；缺失不伪造|
|fx_details|transfer_id ref, debit_entry_id ref, credit_entry_id ref, fee_entry_id? ref, debit_amount, credit_amount, fee_amount?, fee_currency?, actual_rate, rate_snapshot_id? ref|unique transfer；与 entry 金额一致；费用独立|
|budget_nodes|project_id ref, period_id? ref, parent_id? ref, category_id? ref, sure_budget_id? ref, name, start_on,end_on,currency,limit_amount,rollover_enabled,rollover_amount,warning_threshold,lock_version,status|无环，期间包含；相同节点范围去重；rollover>=0|
|budget_versions|budget_node_id ref, actor_id ref, from_data json,to_data json, operation_key|unique operation_key scoped|
|fund_pools|project_id ref, goal_id? ref, name,currency,target_amount?,kind,status,lock_version|goal 唯一；由 Guard 统一计算真实额度|
|pool_movements|pool_id ref, account_id ref, kind, amount money,currency, entry_id? ref, fee_installment_id? ref, operation_key, reversal_of_id? ref|正值，kind allocate/release/consume/refund/reserve/unreserve；unique key；来源额度按账户原币|
|funding_plans|project_id ref, relationship_id? ref, payer_id? ref, pool_id? ref, expected_amount,currency,due_on, recurring_transaction_id? ref,status,lock_version|状态机；金额>0；关联权限|
|funding_matches|plan_id ref, entry_id ref, applied_source_amount, source_currency, applied_plan_amount, plan_currency, rate_snapshot_id? ref, operation_key|unique plan/entry，所有已确认匹配总额<= entry；同一到账默认仅一个 plan，显式拆分例外|
|fee_plans|project_id ref, name,kind,currency,gross_amount, start_on?,end_on?,category_id?,pool_id?,budget_node_id?,recurring_transaction_id?,status|金额非负、日期校验；来源关联唯一性|
|fee_installments|fee_plan_id ref, recurring_occurrence_id? ref,due_on,amount,currency,status|occurrence 唯一；总分期与净应付一致|
|fee_adjustments|fee_plan_id ref, installment_id? ref, kind,amount,currency,reason|kind waiver/scholarship_offset/adjustment；不可与现金奖学金重复|
|fee_payments|installment_id ref, entry_id ref, recurring_allocation_id? ref, amount,currency,source_amount,source_currency,rate_snapshot_id?,kind,operation_key|若有 recurring allocation 唯一；正值、kind pay/refund；同一真实 entry 分配上限|
|receivables|project_id? ref, owner_id ref, counterparty_label, direction, original_entry_id? ref, tracking_account_id? ref, amount,currency,due_on?,status,lock_version|direction receivable/payable；应收应付 tracking account 同租户|
|settlements|receivable_id ref, entry_id ref, amount,currency,source_amount,source_currency,rate_snapshot_id?,operation_key,kind|核销总额<=未清余额；部分付款/退款|
|forecast_snapshots|project_id ref, as_of date, horizon_days, currency, input_version, algorithm_version, assumptions json,result json, status|unique scope/as_of/horizon/input/version；权限过滤|
|forecast_scenarios|project_id ref, owner_id ref,name, assumptions json|校验有界数值、无任意代码|
|notifications|recipient_id ref, event_key,event_type, resource_kind/id?, title_key, payload json,read_at?|unique recipient/event_key；收件人索引|
|notification_outbox|notification_id ref, channel,status,attempts,next_attempt_at?,sent_at?,dedup_key|unique dedup_key；email 发送重试|
|ai_actions|actor_id ref, action_kind, resource_kind/id, payload json, expected_version, grant_version?, confirm_digest?, expires_at, status, result_ref?, reversed_at?|确认 token digest 单次；命令白名单、操作幂等|
|audit_events|actor_id?, family_id, event_kind, resource_kind/id?, request_id, safe_diff json, occurred_at|append-only；不得含凭证/raw statement|
|idempotency_records|actor_id ref, operation, key, request_digest, response_ref?, status, expires_at?|unique actor/operation/key；同 key 不同内容拒绝|
|service_plans|code, name,status, configuration json|平台表 unique code；默认免费核心|
|plan_entitlements|plan_id ref,feature_key,enabled,quota? bigint,window?|unique plan/feature；quota>=0 或 null=未配置|
|subscription_entitlements|subscription_id? ref, plan_id ref, effective_from,effective_to?,status|关联现有 subscription；不可关闭核心|
|usage_events|service, source_event_key, units decimal, cost_amount?,cost_currency?, occurred_at|unique family/service/source_event_key；成本未知为 null|
|platform_permissions|user_id ref, permission_key, granted_by?, revoked_at?|平台授权与 family role 分离；active unique|
|region_configs|country_code,locale?, defaults json,enabled|平台表；地区模板不得承诺实际银行可用|
## 3. 约束与迁移
跨记录金额上限/同租户/父子无环不是普通 CHECK 可解决：使用授权 scope + 同事务锁 + 外键/唯一约束，必要时 composite FK；对真实 ledger entry 删除/编辑设 restrict 或受控解绑/重算，不级联误删事实。所有金额累计以规范化 entry 或分摊为准；计划/投影禁止直接写 accounts.balance。先 additive migrations、可空兼容字段、幂等 backfill、验证约束、再收紧；保留原用户/账户 ID；P0 核查重名/已有同等实体后合并实现。迁移须在明确授权的隔离环境验证新库、旧库升级及恢复；生产不得自动执行。 

## P3 Schema 扩展（2026-11-25）

新增迁移 `20261125100000_create_abroa_parent_access.rb`、`20261125101000_create_abroa_parent_planning.rb`、`20261125102000_create_abroa_funding_plans.rb`、`20261125103000_expand_abroa_parent_planning_proposals.rb`、`20261125104000_create_abroa_funding_suggestions.rb`。

- `abroa_relationships` 保存 `student_user_id`、`parent_user_id`、`student_family_id`、`parent_family_id`、状态和乐观锁；限制学生与家长不能同账户、同家庭。
- `abroa_relationship_invites` 保存不可逆 token / 目标邮箱摘要、原始邀请角色、截止时间及一次性消费状态；原始 token 不入库。
- `abroa_grants` 保存学生授予家长的 project/resource/capability、期限和 revocation；唯一部分索引防止同时存在多个相同活动授权，支持 project 与指定预算/费用/资金池粒度。
- `abroa_planning_drafts` 保存在家长自身家庭；`abroa_proposals` 保存在学生家庭，并引用当前跨租户 Relation、StudyProject、目标及被接受的 `applied_resource_id`。
- `abroa_funding_plans` 保存项目、关系、父母与学生、两边账户引用、资金池、周期计划、审批状态、版本；不创建 Sure `Entry`。
- `abroa_funding_receipts` 用唯一 `entry_id` 引用已存在的学生账务，保存原币金额与固定汇率快照；`abroa_funding_reversals` 引用另一条真实退款 Entry 并保存原币/快照。
- `abroa_funding_notices` 仅家长汇款声明，绝不更新 Account.balance；`abroa_funding_suggestions` 保存学生修改请求、计划预期版本和家长审批状态。
- 所有可重试新增操作都有摘要形式的幂等键及请求摘要；单一真实到账/退款流水有 PostgreSQL 唯一索引，且事务中使用行锁与乐观锁。

跨家庭数据引用仅存在明确的 `Relationship / Grant / FundingPlan` 对象上；Sure 原 `families`、`accounts`、`entries`、`transactions` 均不扩大权限或更改资金来源语义。数据升版以迁移及测试证明为准。


## P4.1 应收应付 Schema（A10，开发验收中）

`abroa_personal_debts` 持有 `family_id`、`owner_id`、可选 `project_id`、关联不可直接当现金使用的 Sure `debt_account_id`（`OtherAsset` / `OtherLiability`）、可选真实源 `source_entry_id`、来源金额/原币/发生日快照、用途与联系人昵称、方向、承担份额、本金、状态/截止日/乐观锁和创建幂等哈希。数据库 CHECK 限制金额与方向；唯一键禁止同一源 Entry 重复声明代付。

`abroa_debt_settlements` 通过真实 Sure `entry_id` 和 `rate_snapshot_id` 保存付款/返款；`kind=payment/refund/source_refund` 分别表示收回/偿还、返还先前核销款和原始商户退款。后一种要求 P1 `abroa_refund_links` 的 `refund_link_id`，将已退款原消费按他人承担比例减记债权；历史结算不能直接改写 Sure Entry。唯一键覆盖 Entry 与租户内幂等请求，部分结算、跨币种保存原币/汇率/映射金额和日期。

可逆迁移：`20261125110000_create_abroa_personal_debts.rb`、`20261125110500_add_source_refunds_to_abroa_debt_settlements.rb`；不修改 P1–P3 历史迁移。开发验证数据库 `abroa_p4_isolated_test`，PostgreSQL 17 独立集群 `abroap4` 端口 55435；不得指向 P2/P3 stage 或生产。

## P4.2 A11 forecast data and cache boundary

Forecasts are read-only computations over Sure's deposited-cash accounts and posted Entry history, P2 confirmed fee installments/payments, P3 received and future planned funding, and P4 personal obligations. No new forecast Ledger, synthetic cash transaction, second accounting subsystem or persistent forecast table is introduced. Historical FX is read through `Abroa::RateSnapshot.quote`; unavailable conversion returns an `incomplete` response and null balances. Aggregation excludes non-cash receivables and target sizes of funds from available cash. Already paid P2 fees are excluded from repeatable daily spend to avoid double counting their next installments.

`Abroa::Forecast::VERSION` identifies the deterministic algorithm; each projection returns a digest of its financial inputs and a UTC data timestamp. `cache_policy=no_persistent_cache` deliberately prevents stale grant-scoped snapshots; input changes therefore invalidate results immediately without cache eviction jobs. The parent projection filters to the granted project and excludes private debt and unrelated parents' unreceived plans.
