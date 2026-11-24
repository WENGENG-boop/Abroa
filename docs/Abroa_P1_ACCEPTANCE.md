# Abroa P1 验收记录（第一轮）

日期：2026-11-24。P1 验收基线：2cae61643；分支后续包含 P2.1 测试预写（ef6192fa9，不纳入本次）及 P1.5 修复（884d636aa）。本次不进入 P2 业务开发。

## 实际证据

- Ruby 3.4.13 语法检查：修复前 P1 相关 72/72 个 Ruby 文件通过，退出码 0；后续改动须在 D 盘环境重新检查。此前用 C 盘 Docker 的构建及下载已停止，不继续使用其存储。
- P1 原有 23 个 Minitest 文件共 88 个用例；新增 4 个 pending/posted 回归测试，另有 P0.5 账本兼容性 4 个用例。本轮共拟运行 96 个行为用例，不包括 P2。
- P1 源码中有 6 个新增数据库迁移及 23 个路由操作。静态存在不代表接口运行通过；OpenAPI 生成及迁移尚未完成。
- D 盘独立 Debian 13 WSL 测试发行版 Abroa-P1-Test 导入成功；磁盘 D:\开发\Abroa\.p1-env\linux\ext4.vhdx。Debian WSL 镜像及 Ruby 3.4.13 源码已下载至 D:\开发\Abroa\.p1-env\downloads 并校验 SHA-256。依赖安装在该发行版内进行。未迁移或清理已有 Docker 数据。
- 独立验收运行器：D:\开发\Abroa\.p1-env\run-p1-acceptance.sh；日志目录：D:\开发\Abroa\.p1-env\logs。使用独立代码快照、测试专用 PostgreSQL/Redis 端口和合成凭证，不使用生产数据库。先迁移，再执行明确列出的 Minitest 和 P1 rswag 请求规格。当前尚无执行通过证据。

## 按验收场景检查

| 场景 | 静态审查结论 | 状态 |
|---|---|---|
| A01-1/2/3 | 邮箱沿用 Sure；新增 Profile、引导及 Google 声明校验。必须执行原认证回归及 P1 行为测试，真实 Google 凭证另验。 | IN_PROGRESS |
| A02-1/2/3 | 历史汇率、缺失处理、实际换汇及费用已实现；待验证迁移、金额精度、历史快照和原账本守恒。跨币种退款快照创建调用链及多币种报告仍需补齐。 | IN_PROGRESS |
| A03-1/2 | 已有来源身份、文件摘要、订单唯一约束和证据；待执行重试及并发验收。 | IN_PROGRESS |
| A03-3/4/5 | 保守匹配、人工关联、钱包标识已存在；自动高置信关联、未知账户分配及相应接口仍待补齐。 | IN_PROGRESS |
| A03-6 | 修复同一稳定 ID 的 pending→posted/closed/failed 状态转换；后续到达的旧 pending 不降级；核心事实变动仍审核。新增 4 个用例尚未运行。退款净消费报告、分类和用户锁还需验证。 | IN_PROGRESS |
| A03-7 | CSV/XLSX/PDF 提取接入已编写；需真实样本及完整 PDF 未知类型确认入账闭环。 | IN_PROGRESS |
| A03-8 | 单次入账撤销、来源引用及退款依赖保护已编写；整批导入回滚、后续修改冲突需完成验证。 | IN_PROGRESS |
| A03-9 | 已有账本同步采集、诊断 API、成功同步回调和结构化错误代码已编写；真实 provider 凭证、重试、撤销和脱敏需运行验证。 | IN_PROGRESS |

**P1 未通过验收。** 所有未运行测试均不能计为通过或失败。外部真实 Google/银行及账单样例需独立验收。完成以上缺口、实际测试、迁移、OpenAPI 与 Sure 相关回归后才允许标记 VERIFIED。

## 第二轮运行验收（2026-11-24）

验收代码 SHA：9009b061c47ef2a1fcae8b3c1ceeca67f7257461；D 盘独立 Debian 13 / Ruby 3.4.13 / Rails 8.1.4.1 / PostgreSQL 17 / Redis 测试环境。

| 实际执行 | 结果 | 日志 |
|---|---|---|
| 六个 P1 数据库迁移 | 6/6 成功 | p1-migrations-712e3daac25be458e162a138c620c0f91b44f368.log |
| P1 Minitest 和 P0.5 账本兼容性 | 99 runs, 542 assertions, 0 failures, 0 errors, 0 skips | p1-round2-minitest.log |
| 原 Sure 18 个相关回归测试文件 | 964 runs, 3287 assertions, 0 failures, 0 errors, 0 skips | p1-original-regression.log |
| P1 RSpec/rswag 请求规格（实际运行） | 23 examples, 0 failures | p1-rspec-current.log |
| 全量 OpenAPI 生成（dry-run，非行为测试） | 508 examples, 0 failures, 89 documentation-only pending；退出码 0 | p1-openapi-generate.log |

日志根目录：D:\开发\Abroa\.p1-env\logs。修复前原版回归 963 runs, 17 failures, 32 errors；中间轮 964 runs, 2 failures, 0 errors；最后一轮全部通过。修复提交 4a83fa31b（账户状态、XLSX 返回值、回执查询）、32f3e8650（原 Google 模拟回调携带真实验证字段，增加拒绝未验证身份测试）、1e40cb780（PDF 禁止换行转换，保留原文件字节和断言）、9009b061c（两组角色用例补齐实际策略字段）。测试环境先生成 Tailwind 资源，并使用隔离集群本地测试账号加载原 fixtures；不修改生产权限。

当前 **已执行的 P1 与相关原版行为测试全绿**。以上不等于全部 P1 需求已完整实现或实盘验收：自动高置信匹配调度、未知付款账户归属、整批导入撤销、退款净消费报表、自动分类及完整对账、并发及真实 Google/银行/账单样本仍需按 A01–A03 补齐；P2 保持暂停。OpenAPI 全量生成的 89 个 documentation-only pending 不计入实际请求测试通过数。
