# Abroa 需求与实施追踪 v1.0
状态定义：PLANNED 尚未实现；IN_PROGRESS 正在实施；IMPLEMENTED 未验；VERIFIED 自动测试及不可执行项代码审查通过；BLOCKED_EXTERNAL 无法模拟且无法完成代码审查的必要外部依赖；FAILED 测试未通过；DEFERRED 后续。原 Sure 功能静态存在不代表 Abroa 已验。本矩阵持续记录实施及实际验收结果；代码存在或局部测试通过不代表整个阶段 VERIFIED。
|需求/范围|任务|验收|复用/新增|状态|实现路径/测试证据|
|---|---|---|---|---|---|
|P0 源码及环境|P0.1–5|A00|审计|IN_PROGRESS|源码与方法/Schema/API 基线审计已记录；D 盘独立 WSL 测试环境已实际运行 Ruby/Rails/PostgreSQL/Redis；P0.5 四个账本兼容用例已通过；全量 lint/Brakeman、Docker 最终部署验收留待独立执行。|
|用户/邮箱/Google/初始化|P1.1|A01|复用+扩展|VERIFIED|Profile、引导、Google 验证与原认证回归通过；最终扩展行为套件 244/244；无真实凭证的 Google 回调路径代码审查，见 Abroa_P1_ACCEPTANCE.md 最终签收。|
|FX 多币种/地区|P1.2|A02|扩展|VERIFIED|历史汇率快照、缺失处理、JPY/KWD 精度、地区/钱包、换汇本金费用及跨币退款报表通过；见最终签收。|
|CONNECT-01,02,03|P1.3–5|A03-1–5|reuse+new|VERIFIED|规范化来源/去重、CSV/XLSX/PDF、账户归属、唯一银行匹配/多候选审核及 PostgreSQL 并发入账通过；见最终签收。|
|CONNECT-04,05,06|P1.5|A03-4–8|extension|VERIFIED|重复订单防护、批量撤销、并发退款、净消费、完整对账及 PDF 双路径互斥通过；见最终签收。|
|CONNECT-07,08|P1.6|A03-9|extension|VERIFIED|同步采集、脱敏诊断、模拟错误、取消/重试、Wise 引用、分类/用户锁通过；真实 provider 无凭证路径代码审查；总计 1237 个实际测试，7/7 迁移，见最终签收。|
|STUDY-01–05|P2.1|A04|新增|VERIFIED|app/models/abroa/{study_project,study_period,project_account,entry_allocation,project_summary}.rb；test/models/abroa/study_project_test.rb、entry_allocation_test.rb、study_allocation_concurrency_test.rb；最终组合 1043/1043 通过，见 P2_BACKEND_ACCEPTANCE.md。|
|BUDGET-01–04,06|P2.2|A05|扩展|VERIFIED|app/models/abroa/{budget_node,budget_version}.rb、预算执行 API；test/models/abroa/budget_node_test.rb；含费用承诺、跨期退款及滚存；1043/1043 组合回归通过。|
|FUND-01,02|P2.3|A06|Goal扩展|VERIFIED|app/models/abroa/{fund_pool,pool_movement,allocation_guard,goal_fund_bridge}.rb；app/models/{goal,goal_account}.rb；test/models/abroa/{fund_pool,fund_pool_concurrency}_test.rb；真实 PostgreSQL 并发、Goal consume/refund 通过，1043/1043 组合回归通过。|
|FEE-01–05|P2.4|A07|Recurring扩展|VERIFIED|app/models/abroa/{fee_plan,fee_installment,fee_settlement,fee_adjustment,fee_reminder_event}.rb；app/jobs/abroa/{sync_recurring_fees_job,fee_reminder_sweep_job}.rb；费用 API、定时任务及测试；1043/1043 组合回归、68/68 全新库、566 OpenAPI 示例及 Brakeman 通过；提醒投递渠道属于 P4.3。|
|家长独立注册/关联/授权|P3.1|A08-1,3,4,5|新增|IN_PROGRESS|关系、邀请、Grant/API、撤销、隔离负向测试已实现；首轮 7/51 通过；完整回归及 Docker 预生产待签收，见 P3_BACKEND_ACCEPTANCE.md。|
|BUDGET-05/家长草稿提议|P3.2|A08-2,3,5|新增|IN_PROGRESS|独立草稿、预算创建/更新、留学项目提议审批、指定预算编辑、版本/幂等已实现；扩展组合 10/61 通过，最终待验。|
|FUND-03–06|P3.3|A09|新增|IN_PROGRESS|拨款计划、周期、汇款声明、学生调整建议、真实 Entry 归集、FX 快照、退款冲正已实现；组合 15/105 通过；退款漂移附加测试及最终验收待签。|
|家长汇总隔离|P3.4|A08/A09|新增|IN_PROGRESS|授权项目摘要、消费/预算/费用/资金池/拨款汇总及负向权限用例已实现；组合 7/62 通过；完整安全审查与预生产待签。|
|RECEIVABLE 个人代付|P4.1|A10|扩展|PLANNED|待填|
|FORECAST 全部|P4.2|A11|扩展|PLANNED|待填|
|NOTIFY 站内/邮件|P4.3|A12|扩展|PLANNED|待填|
|REPORT 项目/家长/FX|P4.4|A13|扩展|PLANNED|待填|
|AI-01–07|P4.5|A14|复用+扩展|PLANNED|待填|
|ADMIN 权限/用户/审计|P5.1|A15-1|扩展|PLANNED|待填|
|ADMIN 订阅/权益/用量|P5.2|A15-2,3|复用+扩展|PLANNED|待填|
|ADMIN 运营/渠道/地区|P5.3|A15|扩展|PLANNED|待填|
|Docker/自托管/云端|P5.4|A16|复用+扩展|PLANNED|待填|
|全后端验收/原版回归|P6|A00–A17|回归|PLANNED|待填|
|前端三端/PWA|P7|A18|后端后实施|PLANNED|待填|
|上线|P8|A19|端到端|PLANNED|待填|
|全球公开留学成本库|后续|未定|新增|DEFERRED|不实现|
|多人共享账本|后续|未定|新增|DEFERRED|不实现|
|用户匿名成本统计|后续|未定|新增|DEFERRED|不采集|
|具体定价/支付|后续讨论|未定|配置|DEFERRED|不启用真实扣费|
## 证据记录模板（每项拆到具体需求/测试）
- 需求ID / 任务ID / 测试ID：
- Git SHA / 实现文件 / 测试路径：
- 环境、命令、退出码、断言及日志：
- 结果（真实服务或 fixture）：
- 遗留风险/阻塞/后续：
- 状态：
P6 审核所有本阶段行必须有真实证据，不能以文档存在、静态代码或 mock 代替验收。外部条件未完成须明确标记，不能自动改 VERIFIED。
