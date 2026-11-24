# P0.2 方法级审计（一）：账务、导入、预算、资金池与授权

基线 fc576847dcb2b33ad9ef8a9003356978fcaa4ce5。下列为实际方法体静态证据，未运行测试。P0.2 尚未结束。

| 证据 | 已核实行为 | Abroa 实施约束 |
|---|---|---|
| app/models/entry.rb:100–218、687–789 | split_once!/resplit!/unsplit_once! 共用锁；split! 要求子金额精确等于父金额，事务内排除父；not_excluded_or_split_parent 用于实际付款匹配；excluding_scheduled 排除未来记录 | 项目分摊不得重复记账，不直接把项目分摊变成第二组账务子项；支付核销与报表分别选取正确口径 |
| app/models/transaction.rb:174–252 | funds_movement、one_time、cc_payment 属于 BUDGET_EXCLUDED_KINDS；loan_payment、investment_contribution 并非全部排除；pending 使用 provider JSON 统一判断 | 保留原版统计规则，另定义留学实际成本及预测现金流口径 |
| app/models/transfer.rb:1–80、179–215、277–320 | 仅允许同 family、不同账户、方向相反；同币种金额相抵；pending 匹配不修改交易 kind；confirm! 才分类；日期范围 pending 4 天、confirmed 30 天；费用有独立交易 | 拨款跨租户不能套用同 family Transfer；实际换汇复用双腿与费用，不能直接将不同币种 total_fee 数字相加作为统一金额 |
| app/models/account/provider_import_adapter.rb:39–130、832–885 | 按 account/source/external_id 查找，保护用户修改和 import_locked；allow_heuristic_matching 可关闭；原版同账户人工/CSV 重复查找默认不要求名称，精确日选择最早候选，排除拆分子项 | 新增跨来源证据匹配时关闭危险的自动启发式路径；同日同额不作为自动合并的充分证据；保留原版已有流程 |
| app/models/budget.rb:48–93、169–252 | period_for 仅自然月或定制月；find_or_bootstrap 含个人/家庭预算；transactions/cash_accounts 按用户或可访问账户筛选；未指定 current_user 的家庭路径为宽范围；free_cash 扣除同批账户的 Goal 预留 | 新项目多周期预算以独立计划层扩展，复用底层账务读取；授权查询必须显式传递访问范围；保留既有月预算 |
| app/models/goal.rb:186–264、731–810；app/models/goal_account.rb:1–57 | 非释放 Goal 统一池化；整账户 claim 使用 PostgreSQL 事务 advisory lock；固定分配允许按比例折算超配；consume! 锁 Goal 和 link、按交易日期汇率计算、拒绝超额和 maintained goal 消费 | 复用同一资金 backing 计算；新严格资金池须在共享锁/事务下核验固定预留及已有 Goal；退款恢复与消费幂等仍需核实 |
| app/models/recurring_occurrence.rb:1–125 | 存储 scheduled/paid/skipped/missed，其他展示状态根据日期及分配派生；confirmed allocations 汇总；拆分付款按消费份额计算；固定 CLOSE_EPSILON 0.01 | 留学费用复用分配和周期机制；分期、减免、押金、退款及不同币种精度须扩展；不制造重复账单 |
| app/controllers/api/v1/base_controller.rb:55–129、220–259、345–382 | OAuth 与 X-Api-Key 并存，检查用户 active；账户写权限由 AccountPolicy 另验；guest 写保护；family 校验拒绝跨租户；API 建立无 impersonation 的临时 Current.session | 家长授权需独立资源投影，不切换 Current.family 或放宽原版 family 权限；授权撤销和后台任务另验 |
| app/models/ai/router.rb:1–32 | 按用户/family、consent、能力选择路由；可用性不代表端点存活 | 保留路由和 consent；跨租户工具 scope、确认执行和真实可用性独立验证 |

## 后续方法审计

认证/OIDC 账号绑定与注册、完整导入/回滚、报表与退款、Goal backing/退款、Recurring allocator 与并发、AI 写工具确认、订阅 gating、后台任务和现有测试断言仍需阅读。P0.4 的最终 schema/API 尚未定稿；P0.5 golden fixtures 尚未实现。

## 验收状态

本次只读源码，未运行 Ruby、数据库、Docker 或测试。原版测试路径见 P0.1 记录，不能标记 VERIFIED。继续 P0.2；P0.3 仍受环境阻塞。


## P0.2 第二批：身份、回滚、周期分配、AI 写路径

以下源码及测试声明均已直接读取，尚未执行。

| 证据 | 已核实行为 | Abroa 实施约束 |
|---|---|---|
| app/models/oidc_identity.rb:1–125 | provider + uid 唯一校验；身份锁与黑名单；保存 issuer；旧身份 issuer 为空或配置无 issuer 时兼容放行；IdP 可映射原版角色 | Google 专用入口须核实 issuer/subject/email_verified；不得把 IdP group 映射为 Abroa 平台权限；新身份不沿用空 issuer 兼容例外 |
| app/controllers/api/v1/auth_controller.rb:217–361 | 绑定既有账号须密码验证；一次性链接码原子领取；身份、审计、设备 token 事务；新 SSO 用户可接受 Sure family 邀请或新建 family | 学生与家长分别建立独立 family；Abroa 关联邀请不复用加入同 family 的语义；Google Web 流程及真实凭证仍需验收 |
| app/models/import.rb:276–351；app/jobs/revert_import_job.rb | 已完成/正在回滚批次拒绝重复 publish；revert 在事务中销毁导入账户及顶层 Entry，之后同步；回滚失败可重试 | 跨源来源记录和用户后续修改必须独立记录；不能直接调用原版破坏性 revert 作为 Abroa 来源撤销 |
| app/models/recurring_transaction/allocator.rb:30–151 | occurrence 行锁及按拆分根 Entry 的事务 advisory lock；容量包含 split counterpart；跨币种 source_amount；允许 entry-less 手工支付；可选 cap_at_remaining | 留学费用已支付事实要求真实 Entry；付款占用必须纳入统一锁和原版容量，不能双重核销；无 Entry 只可表示待确认计划 |
| app/models/assistant/function/update_budget.rb:90–151；create_transaction.rb:138–242 | update_budget 在事务内直接写预算；create_transaction 直接写 Entry，有可选稳定外部 ID 幂等、可写账户 scope | 聊天写入口必须先产生提议，确认后由服务器授权执行；幂等需覆盖所有确认动作，不能仅依赖调用方提供 external_id |
| app/models/subscription.rb:7–52 | active 状态要求 stripe_id，存在 synthetic/demo 判别 | 免费核心与套餐权益独立，不伪造 Stripe 状态或启用真实扣费 |

已有测试声明证据：entry_split_test.rb 覆盖拆分守恒、禁止转账/重复拆分；transfer_test.rb 覆盖同租户、相反金额、确认分类及删除恢复；recurring_transaction/allocator_concurrency_test.rb 覆盖并发超分配、匹配与手工核销竞争；assistant/function/update_budget_test.rb 覆盖跨 family 分类拒绝及事务回滚；api/v1/auth_controller_test.rb 覆盖开放注册限制、邀请、账号创建及无效设备。Goal 测试包含历史整账户重叠兼容情形；新增约束不应破坏既有数据读取。

P0.2 仍需完整核查 Web OIDC、报表/退款、provider/导入子类、Goal backing、AI 工具分派、订阅 gating、后台任务、schema/migration 及测试断言。未标记完成。
