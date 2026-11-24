# P0.1 基线核实记录

- 审计日期：2026-11-24；上游基线：`fc576847dcb2b33ad9ef8a9003356978fcaa4ce5`，原分支 main。
- 锁定依赖：Ruby 3.4.13、Rails 8.1.4.1、pg 1.5.9、Redis gem 5.4.0、Sidekiq 8.0.5、Minitest 6.1.0、RSpec Rails 8.0.2、rswag 2.17.0；Biome ^1.9.3。
- 目录：app/（Rails 模型、控制器、组件、JS）、db/（schema/migrations）、test/（行为测试）、spec/（API 文档）、config/、lib/、bin/、docs/、mobile/、desktop/。
- 运行架构：Compose 示例使用 web、worker、PostgreSQL 16、Redis 及备份服务。Docker CLI 29.8.0 可执行，但 Linux Engine 管道不存在；当前 PATH 未发现 ruby、bundle。未启动服务、运行迁移或执行测试。
- 原版能力静态清单见 Abroa_SOURCE_AUDIT.md；以下补充方法与测试入口（静态发现，未执行）。

| 领域 | 原版方法/入口 | 现有测试入口 |
|---|---|---|
| 认证与权限 | API::V1::AuthController#signup/#login/#sso_exchange/#sso_link/#sso_create_account；BaseController#authenticate_request!/#require_api_account_permission!/#ensure_current_family_access | test/controllers/api/v1/auth_controller_test.rb |
| 账务与拆分 | Entry.excluding_split_parents、#split_once!、#resplit!、#protected_from_sync?；Transfer#confirm!/#kind_for_account | test/models/entry_test.rb、entry_split_test.rb、transfer_test.rb |
| 导入 | Account::ProviderImportAdapter#import_transaction/#find_duplicate_transaction/#find_pending_transaction_fuzzy；Entry.reconcile_pending_duplicates | test/models/account/provider_import_adapter_test.rb、transaction_import_test.rb、pdf_import_test.rb |
| 预算及报表 | Budget.period_for、#transactions、#actual_spending、#free_cash、#convert_to_budget_currency；Family#income_statement/#balance_sheet | test/models/budget_test.rb、personal_budget_test.rb、test/integration/mixed_currency_test.rb |
| 资金池 | Goal.pooled_allocations_for、.lock_whole_account_claims!、#consume!、#backing_within | test/models/goal_test.rb |
| 周期费用 | RecurringTransaction / RecurringOccurrence / Allocator | test/models/recurring_transaction_test.rb、recurring_occurrence_test.rb、recurring_transaction/allocator_concurrency_test.rb |
| AI | Ai::Router#resolve；Assistant::Function 写操作 | test/models/ai/router_test.rb、assistant/function/update_budget_test.rb、assistant/function/create_transaction_test.rb |
| 订阅 | Subscription#synthetic?、#pending_cancellation?；active 状态校验 stripe_id | test/models/subscription_test.rb |

## 待解决的规格差异

1. Sure 的现金流 Entry 负数为流入、正数为流出；资产估值不能套用现金流符号。
2. 原版普通资金转移和信用卡还款不计预算消费；贷款还款、投资贡献有不同预算口径。Abroa 需保持原版行为，另定义留学成本口径，不可统一排除所有 transfer。
3. 原版 Goal 已有池化分配及账户级锁，需先核实互斥、核销与退款路径，避免重复建立额度账本。
4. 原版预算已有自定义月起始日和个人预算；不能由 start_date/end_date 字段直接推断支持任意层级。
5. P0.2 尚需读取完整方法体、权限路径、迁移与相关测试；P0.4/P0.5 尚未定稿。
6. P0.3 运行验收受环境阻塞。待明确授权隔离环境准备及数据库操作后运行，不得将静态结果标为测试通过。

P0.1 静态核实完成；P0 整体仍 IN_PROGRESS。
