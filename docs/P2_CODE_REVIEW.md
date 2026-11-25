# Abroa P2 独立代码审查与修复记录

审查日期：2026-11-25。审查基线：`f47538aff`，P1 原版基线：`66b68eac4`。分支：`abroa/development`。只审查及修改 `D:\开发\Abroa\Abroa`；测试、日志与依赖位于 D 盘隔离 WSL/数据库。

## 审查范围

P2.1–P2.4 模型、控制器和任务的 family/owner 权限、实际 Entry 与虚拟池账本边界、Goal 资金守恒、费用及分期的生命周期、重复请求、锁顺序、周期账单状态/日期、跨币种退款、Schema/API 文档与 Sure 原版兼容。重点审查了 `study_project.rb`、`study_period.rb`、`entry_allocation.rb`、`budget_node.rb`、`project_summary.rb`、`fund_pool.rb`、`allocation_guard.rb`、`pool_movement.rb`、`goal_fund_bridge.rb`、`fee_plan.rb`、`fee_installment.rb`、`fee_settlement.rb`、`fee_adjustment.rb`、两个 P2.4 定时任务与 Sure 原有 provider adapter。所有修复均保留原版账本为唯一真实账务来源。

## 已复现并修复的问题

|ID|严重性|问题/危害|已实施的修复及证据|
|---|---|---|---|
|CR-01|中|取消费用计划后仍可撤销已批准减免，改变历史应付款。|在 `FeeAdjustment.void_for!` 重新校验费用仍处于 active；失败用例及回归：`p2-code-review-red1.log`、`p2-code-review-fixes-final.log`。|
|CR-02|高|Sure 账单 snoozed 后，导入按原 due_on 过滤，漏掉有效到期日。|按 Sure 自身 `GREATEST(due_on,snoozed_until)` 过滤并二次校验 effective_due_on；`p2-code-review-red1.log` 与后续绿测。|
|CR-03|高|不同分期复用同一客户端幂等键，资金池流水键相撞；变更算法时旧请求重试有双扣风险。|衍生分期范围内的流水键，且首次进入资金池前检查旧 settlement 的已有幂等键；新增跨分期及旧版重放测试，`p2-code-review-green2-red3.log` 与绿测。|
|CR-04|中|Sure 周期源暂停或结束后，后台仍继续导入旧 occurrence。|fan-out 与单计划执行均检验 Sure `active?`；`p2-code-review-paused-red.log` 与绿测。|
|CR-05|高|费用已有未付款分期仍可改币种、类型或资金池，破坏既有义务的来源一致性。|分期或调整存在即冻结上述字段（金额和可允许的非来源字段不受影响）；`p2-code-review-provenance-red.log` 与绿测。|
|CR-06|中|跨 120 天窗口的周期条数大于 100 时，后台每次均整批失败。|保留人工导入每批不超过 100 的限制，后台仅在特定超限错误时递归拆日期窗口，幂等运行；`p2-review-dense-red.log`、`p2-review-dense-green.log`。|
|CR-07|高|外币 Goal 消费按购买日汇率记账，但退款按退款日汇率冲回，导致全额退款被拒绝或产生外币余额差。|基于 `RefundLink` 原购买日汇率恢复原消耗，合并多来源退款按权重分摊，来源须确为同一 Goal 资金池既有消费；`p2-review-goal-fx-red.log`、`p2-review-goal-fx-green1.log`、`p2-review-goal-fx-multi-green.log`。|
|CR-08|高|Sure 预定交易匹配会误认未来日期的 split 子交易；同时旧测试混用 OS 与 Rails 日期造成跨时区失败。|在 scheduled 匹配时排除 `parent_entry_id` 子交易；两个旧测试统一用 `Date.current`，额外新增未来拆分子交易负向测试；`p1-original-two-isolated-review.log`（P1 基线亦复现）、`p2-review-sure-split-future-red.log` 和 `p2-review-sure-3-green.log`。|

上述失败样例先以失败证明缺陷，再修复、运行针对性测试，未放宽测试断言、权限校验或金融上限。

## 验收证据

- 修复后 Sure+Abroa 合并回归：**1,189 tests / 4,599 assertions / 0 failures / 0 errors / 0 skips**，退出码 0。日志：`D:\开发\Abroa\.p2-env\logs\p2-code-review-regression-reviewed-fx.log`。
- 资金池外币回归：**28 tests / 161 assertions / 0 failures/errors**；多笔历史汇率用例组合：**16 tests / 88 assertions / 0 failures/errors**。日志：`p2-review-goal-fx-green1.log`、`p2-review-goal-fx-multi-green.log`。
- 周期密集同步：**6 tests / 28 assertions / 0 failures/errors**；日志：`p2-review-dense-green.log`。
- Sure 原版测试的两处失败在 P1 不含任何 P2 修改的独立快照及数据库中重现；不是 P2 引入的回归。现已通过修正测试日期与补充真实业务边界修复，三项验证 **3 tests / 16 assertions / 0 failures/errors**。
- 新 API 未修改，仍沿用 P2 原有 566 个通过的 OpenAPI 生成示例、89 个既有文档待处理示例。代码修改未引入新迁移。
- 全新隔离数据库 `abroa_p2_review_fresh_test` 从 `db:schema:load` 创建（未复用或删除旧数据库），运行 **77 tests / 446 assertions / 0 failures / 0 errors / 0 skips**，退出码 0。日志：`p2-code-review-fresh.log`。
- RuboCop 对 **13 个修改文件检查，0 offenses**；`p2-review-final-lint.log`。
- Brakeman：**0 errors / 0 security warnings / 8 existing ignored warnings**；`p2-review-final-brakeman.log`。
- API endpoint consistency verifier：通过；`p2-review-final-consistency.log`。本次审查未更改端点、rswag 契约或数据库迁移。

## 验收边界

这是 **P2 后端代码及模拟数据/隔离数据库验收**，不是生产部署与真实通知投递证书。实际定时任务生产触发、真实 Google/银行账号、通知投递、前端与后续 P3–P8 阶段仍需各自验收。原 Sure 的真实 Entry、Transaction、Account balance 不因虚拟资金池、减免、周期导入而生成额外现金流水。

## 追溯

原 P2 验收提交：`f47538aff`。审查修复提交：`2b18987e6`（费用生命周期、Recurring/幂等性）、`ba54fb31c`（Goal 历史汇率退款）、`78c086577`（Sure provider split 子交易和时区测试）。审查文档单独提交；不推送远端，既有不跟踪文件保持原状。
