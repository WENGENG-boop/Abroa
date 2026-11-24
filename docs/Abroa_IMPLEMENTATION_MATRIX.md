# Abroa 需求与实施追踪 v1.0
状态定义：PLANNED 尚未实现；IN_PROGRESS 正在实施；IMPLEMENTED 未验；VERIFIED 有实际通过证据；BLOCKED_EXTERNAL 缺凭证/真实样例；FAILED 测试未通过；DEFERRED 后续。原 Sure 功能静态存在不代表 Abroa 已验。本矩阵持续记录实施及实际验收结果；代码存在或局部测试通过不代表整个阶段 VERIFIED。
|需求/范围|任务|验收|复用/新增|状态|实现路径/测试证据|
|---|---|---|---|---|---|
|P0 源码及环境|P0.1–5|A00|审计|IN_PROGRESS|源码与方法/Schema/API 基线审计已记录；D 盘独立 WSL 测试环境已实际运行 Ruby/Rails/PostgreSQL/Redis；P0.5 四个账本兼容用例已通过；全量 lint/Brakeman、Docker 最终部署验收留待独立执行。|
|用户/邮箱/Google/初始化|P1.1|A01|复用+扩展|IN_PROGRESS|Profile、引导、Google 已验证邮箱/issuer/subject 及改配后身份拒绝；相关行为与原认证回归已通过，真实 Google 凭证和端到端回调另验。|
|FX 多币种/地区|P1.2|A02|扩展|IN_PROGRESS|历史汇率快照、缺失处理、地区/钱包、真实换汇本金费用、跨币退款及净消费报表已通过合成数据测试；历史报表/实际外部数据及完整并发验收待完成。|
|CONNECT-01,02,03|P1.3–5|A03-1–5|reuse+new|IN_PROGRESS|规范化来源/去重、CSV/XLSX/PDF 解析、预览、支付来源与实际账户确认、唯一银行匹配及多候选审核已实现并测试；真实银行/支付宝/微信样本及并发专项待验证。|
|CONNECT-04,05,06|P1.5|A03-4–8|extension|IN_PROGRESS|人工重复订单保护、审计回滚、整批原子撤销、部分/跨币退款、孤立退款异常、净消费、对账确认/撤销及撤销后回滚全部通过相应回归；真实账单、多来源并发/完整业务边界待验。|
|CONNECT-07,08|P1.6|A03-9|extension|IN_PROGRESS|同步后采集、脱敏诊断、结构化错误、Wise 真实引用、自动化偏好、原规则自动分类、用户锁、对账已实现；7 个 P1 迁移、130/130 Minitest、29/29 API、964/964 原版相关回归；真实 provider 凭证、实际重试/撤销和专项并发待验。|
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
