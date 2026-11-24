# Abroa 需求与实施追踪 v1.0
状态定义：PLANNED 尚未实现；IN_PROGRESS 正在实施；IMPLEMENTED 未验；VERIFIED 有实际通过证据；BLOCKED_EXTERNAL 缺凭证/真实样例；FAILED 测试未通过；DEFERRED 后续。原 Sure 功能静态存在不代表 Abroa 已验。此版本仅文档与初步静态审计，不修改代码、不运行测试。
|需求/范围|任务|验收|复用/新增|状态|实现路径/测试证据|
|---|---|---|---|---|---|
|P0 源码及环境|P0.1–5|A00|审计|IN_PROGRESS|P0.1 静态基线核实完成，见 Abroa_P0_BASELINE.md；P0.2 方法体审计未完成；P0.3 Docker Engine 未运行、Ruby/Bundler 不在 PATH，测试未执行|
|用户/邮箱/Google/初始化|P1.1|A01|复用+扩展|PLANNED|待填|
|FX 多币种/地区|P1.2|A02|扩展|PLANNED|待填|
|CONNECT-01,02,03|P1.3–5|A03-1–5|复用+新增|PLANNED|待填|
|CONNECT-04,05,06|P1.5|A03-4–8|扩展|PLANNED|待填|
|CONNECT-07,08|P1.6|A03-9|扩展|PLANNED|待填|
|STUDY-01–05|P2.1|A04|新增|PLANNED|待填|
|BUDGET-01–04,06|P2.2|A05|扩展|PLANNED|待填|
|FUND-01,02|P2.3|A06|Goal扩展|PLANNED|待填|
|FEE-01–05|P2.4|A07|Recurring扩展|PLANNED|待填|
|家长独立注册/关联/授权|P3.1|A08-1,3,4,5|新增|PLANNED|待填|
|BUDGET-05/家长草稿提议|P3.2|A08-2,3,5|新增|PLANNED|待填|
|FUND-03–06|P3.3|A09|新增|PLANNED|待填|
|家长汇总隔离|P3.4|A08/A09|新增|PLANNED|待填|
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
