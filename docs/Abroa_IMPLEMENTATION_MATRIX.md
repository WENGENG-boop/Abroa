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
|家长独立注册/关联/授权|P3.1|A08-1,3,4,5|新增|VERIFIED|一次性邮箱邀请、接受/拒绝/撤销、关系/Grant/跨租户隔离；真实 HTTP 授权撤销前 200 后 404；全量 19164/116966 与追加 21/215 测试均 0 失败，见 P3_BACKEND_ACCEPTANCE.md，业务 SHA 119317b9c。|
|BUDGET-05/家长草稿提议|P3.2|A08-2,3,5|新增|VERIFIED|家长独立草稿、创建/修改预算与留学项目提议、学生审批、限定授权的直接预算修改、版本/幂等/审计；模型及 API 负向测试、完整 Rails 回归、预生产预算审批均通过，见 P3_BACKEND_ACCEPTANCE.md。|
|FUND-03–06|P3.3|A09|新增|VERIFIED|拨款计划/周期/声明、学生建议、真实已入账 Sure Entry 唯一匹配、历史 FX、真实退款流水冲正与漂移检测；独立预生产净到账 300 GBP、账本未生成虚假现金，完整回归及并发测试通过，见 P3_BACKEND_ACCEPTANCE.md。|
|家长汇总隔离|P3.4|A08/A09|新增|VERIFIED|项目/消费/预算/费用/资金池/现金/拨款的受限投影，账户流水默认脱敏；越权 404、授权撤销即时生效；真实 Web HTTP、Brakeman 0 安全警告及完整回归通过，见 P3_BACKEND_ACCEPTANCE.md。|
|RECEIVABLE 个人代付|P4.1|A10|扩展|VERIFIED|基于 Sure 真实已入账 Entry 的个人代付、第三方债务、收款与退款/历史 FX，幂等和双 PostgreSQL 并发通过。P1–P4 Rails 全量 19253/117659 零失败、Docker P4 财务闭环及 P3 历史数据迁移已验证；详见 P4_BACKEND_ACCEPTANCE.md。|
|FORECAST 全部|P4.2|A11|扩展|VERIFIED|确定性现金流、费用/拨款/租金/生活费/历史 FX 预测和异常消费监测，学生/家长实时 Grant 投影；全量 19253/117659、隔离 Docker 业务与 P3 迁移验证通过，详见 P4_BACKEND_ACCEPTANCE.md。|
|NOTIFY 站内/邮件|P4.3|A12|扩展|VERIFIED|站内通知、已读/偏好、Email Outbox/静默、失败及 uncertain 处理；五个 Sidekiq Cron 在 P4 Docker Worker 重启前后正常。P1–P4 全量通过；真实 SMTP 收件不在此验收，详见 P4_BACKEND_ACCEPTANCE.md。|
|REPORT 项目/家长/FX|P4.4|A13|扩展|VERIFIED|Sure Ledger 只读财务报表、历史 FX、第三方代付比例、家长小样本保护、CSV/JSON 导出与当前 Grant 再校验。修复 ActiveStorage signed blob 绕过后 134/1844 专项及 19253/117659 全量通过；P4 Docker 验收通过。|
|AI-01–07|P4.5|A14|复用+扩展|VERIFIED|自定义加密模型配置与安全网络限制、授权财务解释/分类建议、用量；预算/费用/资金池提案人工确认、幂等/补偿、Sure旧 AI 写工具隔离。专项21/159、并发1/7、v14 backfill、19253/117659 全量与 Docker 通过；真实模型连通性未在范围内。|
|ADMIN 权限/用户/审计|P5.1|A15-1|扩展|VERIFIED|平台RBAC/审计/封禁/旧Sure impersonation防绕过；Git a082b05d4；P5.1专项26/143零失败，Brakeman 0警告；最终全量19328测试/118189断言/0失败/0错误，见 docs/P5_BACKEND_ACCEPTANCE.md。|
|ADMIN 订阅/权益/用量|P5.2|A15-2,3|复用+扩展|VERIFIED|独立套餐/订阅/用量/模拟支付，核心业务免费，自托管无官方订阅；Git ba220b8e9，专项15/82与并发8/35均绿；最终全量19328测试/118189断言/0失败/0错误。|
|ADMIN 运营/渠道/地区|P5.3|A15|扩展|VERIFIED|真实用户/银行/AI/导入/运维汇总、允许配置的地区渠道参数/治理申请；Git 0716d1b6f，专项14/114、Brakeman、API rswag通过；最终全量19328测试/118189断言/0失败/0错误。|
|Docker/自托管/云端|P5.4|A16|复用+扩展|VERIFIED|生产候选 Web/Worker/PostgreSQL/Redis 四容器健康、HTTP200和401、Worker实际执行、原Sure/P4历史升级+金额指纹一致、备份恢复、新库Schema与加密密钥重启验收；隔离Redis与PostgreSQL故障恢复、最终全量19328/118189/0/0、P5.4镜像SHA6f8fc5f19重建并复验通过。|
|全后端验收/原版回归|P6|A00–A17|回归|VERIFIED|独立 P6.1 Git 421c68e13、P6.2 Git e559aeb9a；PG17/Redis7 最终 Rails 19332 runs/118269 assertions/0失败/0错误/9项逐一解释旧跳过，退出0；真实 Selenium 原 Sure System 511 runs/2817 assertions/0失败/0错误/0跳过、退出0；Brakeman 0未忽略警告、RuboCop3884/0、ERB857/0、Biome JS Lint158/0、API和rswag通过；20,000条账本PG性能、Sure/P4升级/恢复、Redis/PG故障注入、真实Sidekiq重试、云端/自托管HTTP均通过。额外 Biome 全仓格式/导入排序问题属P7且未通过；真实银行/Google/SMTP/AI/付款供应商为P8外部未联调项；详见 P6_FINAL_SIGNOFF.md、P6_SECURITY_AUDIT.md 和 D盘P6证据日志。|
|前端三端/PWA|P7|A18|后端后实施|IN_PROGRESS|留学项目入口、列表、创建与详情已局部实测；浏览器1/3及控制器98/523零失败，详见 P7_FRONTEND_IMPLEMENTATION.md；三端其余功能及PWA未验收。|
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
