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

## 自动高置信关联补验

测试提交 2fdb085b7：102 runs，3 errors（未实现自动关联统计），其余测试正常；实现提交 0b441650a：102 runs，563 assertions，0 failures，0 errors，0 skips。发布前先入库全部证据；仅唯一银行记录、显式共同订单号、同账户/金额/币种/方向、无其他竞争订单及无钱包账户冲突的场景自动关联已有交易。不新增 Entry；写入前重新匹配，使用独立 savepoint；冲突保留人工审核，记录 automatic 审计标识。新增回执 auto_linked_count。
接口规格再次实际执行：23/23 通过。

## 批量回滚、净消费与资金归属补验

- P1.5 批量回滚：d14d66f7c（红：106 runs，2 failures、2 errors），8ce4ca9b4（绿：106 runs、596 assertions），ca1818abd（跨批次共享来源保护，107 runs、604 assertions）。批次记录内部来源所有权清单；只撤销本批次且未被修改的效果，保留原始来源与审计，遇到共享引用、缺失所有权清单或后续修改整批拒绝，禁止重复回滚后重发。
- P1.5 净消费：e0e92e5d2（红：112 runs、5 errors），8f24d1965（绿：112 runs、632 assertions，25/25 request specs）。报告使用实际退款到账日、实际退款原币，缺失汇率/失效分配返回 incomplete/null，不修改原账本；未匹配入账仅称未分配入账，不确认为收入。GET /reports/consumption。
- P1.4 资金归属：dcc1ba5db（红：114 runs、2 failures），d2623653d（多账户归属实现，发现 PostgreSQL DISTINCT 锁查询回归），cbb3b68d8（锁查询修复：114 runs、653 assertions、0 failures、0 errors、0 skips；26/26 request specs）。未知渠道资金需人工确认实际账户，保留归属历史与原始证据；同一账户所有者与两端写权限、账户类型、币种、版本及跨批次证据保护。POST /reviews/:id/assign-account。
- 最新代码重跑原 Sure 相关回归及 OpenAPI 生成结果见下方实测日志。D 盘隔离测试环境不变。
- 尚未完成：完整对账、自动分类与用户锁、可调自动化策略、真实 Google/银行/账单样本、完整并发及外部验收。上述绿色用例不等于全部 P1 验收完成。

代码 SHA: cbb3b68d81dafbaf1109e63902138c87c96e6677
- Sure 回归: 964 runs, 3287 assertions, 0 failures, 0 errors, 0 skips
- OpenAPI dry-run: 511 examples, 0 failures, 89 pending（非行为测试）

## 第一轮代码审查整改及复验

审查基线：267b453e0。下列是该轮八项问题的整改结果，不等于真实外部服务已完成验收。

| 问题 | 修复与实际证据 |
|---|---|
| 重复人工关联不同支付订单 | e3b175fa6 新增回归；f3af0ef8a 在交易锁内拒绝已有其他支付宝/微信来源的关联，保留原交易和审核状态。 |
| 对账撤销后回滚失败 | 同上。保留完整交易指纹，确认前、确认后及经验证撤销后记录精确指纹；仅沿已审计的完整状态转换恢复回滚资格，不忽略时间戳或人工修改。 |
| Google 提供商改配 | 同上。已存 Google issuer 的身份在配置改成非 Google 时不能按旧身份认证；核对已安装的 Google OAuth 1.2.1 和 OIDC 0.8.0 实现，保留服务器端回调验证。真实 Google 凭证另验。 |
| 银行引用缺失 | ebc8d4ab9 红测；5be73a366 读取 Wise 已有 provider-owned payment_reference，严格检查 statement_id 与 external_id；不从交易描述推断。允许相同事实下补充此前缺失引用，自动关联前再次核验。其他 provider 无可靠结构化字段时保留人工审核。 |
| 原消费删除后孤立退款 | f3af0ef8a 对可见退款到账记录且原消费已删除的异常分配标记 incomplete，净消费和未分配入账返回 null，不暴露删除的原消费明细。 |
| schema 未同步 | c03b5b2b5 使用真实生成的 profile schema 更新 import_automation 与版本至 2026_11_24_135100；其他原 schema 不变。独立新数据库 schema:load 成功，7 个 P1 迁移均 up，新库行为 125/125、请求规格 29/29。 |
| 三个对账接口规格缺失 | edac77276 添加预览、确认、撤销 rswag；c03b5b2b5 合并生成的 24 路径、29 操作、17 Abroa schemas，原路径/schema/security 语义不变。e0aafb40c 新增对账和净消费控制器的行为与授权测试。 |
| 实施矩阵过期 | 本次同步 P0/P1 的实际测试、完成范围、剩余外部验证。 |

前置自动分类/自动化配置及对账：b4c557f3b、293ac2408、267b453e0；分类使用原 Sure 单一明确规则，尊重用户锁与手工分类；对账复用余额和实际交易，确认、撤销不改变原金额。

红测：124 runs、3 failures、1 error；修复后 124 runs、705 assertions、全绿；Wise 引用红测 125 runs、1 failure，修后 125 runs、712 assertions、全绿。
最新行为/授权测试 e0aafb40c：130 runs、744 assertions、0 failures、0 errors、0 skips；同一快照 29 request specs、0 failures。业务代码 edac77276 的相关原 Sure 回归：964 runs、3287 assertions、0 failures、0 errors、0 skips。共 1123 个独立测试用例，4031 次 Minitest 断言，均通过。OpenAPI 生成 514 examples、0 failures、89 文档专用 pending（dry-run，不计入行为测试）。独立新库 abroa_p1_fresh_c03b5b2b 的 schema:load 与 125 Minitest、29 request specs 均实际成功（重复执行，不重复计入总数）。

日志：D:\开发\Abroa\.p1-env\logs\p1-review-before.log、p1-review-repair.log、p1-provider-reference-before.log、p1-provider-reference-repair.log、p1-audit-final-minitest.log、p1-audit-final-rspec.log、p1-fresh-migrations.log、p1-fresh-minitest.log、p1-fresh-rspec.log、p1-original-regression.log、p1-openapi-generate.log、p1-round2-minitest.log、p1-rspec-current.log。API consistency 脚本退出码 0；现有上游 FinanceKit OAuth、transactions/transfers rswag 断言警告仍原样保留；Abroa refund-links 行为测试在 source_reviews_controller_test.rb 内，未重复测试。

第一轮列出的八项审查问题均已整改并有代码/运行证据。P1 最终验收仍需真实 Google OAuth、实际银行连接及真实账单样本、并发专项、所有验收场景完整覆盖；未将这些未取得证据的项目标为 VERIFIED。P2 尚未开始业务代码。所有验收数据、下载和运行日志存放在独立 D 盘环境。

## 验收口径更新（2026-11-24）

用户确认不需要真实 Google/银行连接/真实账单联调。现有 1123 个通过用例与 7 个迁移、新库验收继续有效；外部真实数据不再阻塞 P1，无法执行的场景须代码审查通过。本地可运行的并发与重试等场景仍需实际验证，不能仅因旧测试全绿而直接宣布未覆盖项目通过。后续验收以 Abroa_ACCEPTANCE.md 最新口径为准。

## P1 最终签收（2026-11-24）

验收口径：依据 9a5606536 及用户确认，采用隔离运行、模拟第三方服务和无法真实执行项的针对性代码审查；真实账号、真实账单及生产联调不作为阶段门槛。

最终业务代码：03f8a88d6。最终测试快照：db7889c34（与该业务版本相比，仅修正原 OIDC 测试夹具，生产代码、迁移、路由及规格不变）。

| 验收 | 证据和结论 |
|---|---|
| A01-1 | 原 Auth/Sessions/Registrations/Passwords/PasswordResets/Onboardings/OAuthRegistration/OidcIdentity 等测试，注册、登录、退出、重置密码、SSO 绑定及租户隔离走原流程。通过。 |
| A01-2 | GoogleIdentityTest、AbroaGoogleLoginTest、原 Auth/OIDC 回归覆盖已验证身份、issuer/subject、改配、阻止未验证与已封禁身份、关联保护。实际 Google 服务不能在无凭证环境中调用：审查 OmniAuth 服务端回调、配置 issuer、签名/nonce 校验及 linking state 约束通过；不声称真实连接已成功。 |
| A01-3 | ProfileTest、OnboardingsControllerTest 及原 OnboardingsControllerTest：可跳过、重复请求、版本和幂等，未强制创建项目。通过。 |
| A02-1/2/3 | RateSnapshotTest、AccountProfileTest、FxDetailTest、NetConsumptionTest、CurrencyControllerTest：历史快照、过期/缺失汇率、JPY/KWD 精度、真实本金/手续费分离、历史退款报表；不从当前率改写快照。通过。 |
| A03-1 | LedgerConcurrencyTest 的两个独立 PostgreSQL 连接同时创建同一 external_id、同时采集同一来源；ProviderImportAdapterTest 原锁定/重试回归。修复 03f8a88d6 使用账户行锁与唯一索引，两个并发调用返回同一条 Entry。通过。 |
| A03-2/3/4/5 | SourceRecordTest、SourceMatcherTest、StatementParserTest、StatementIntakeTest：同文件/相同外部订单去重、唯一显式引用、多个候选、未知账户确认与跨租户拒绝。通过。 |
| A03-6 | SourceReviewTest、SourceRecordTest、RefundLinkTest、NetConsumptionTest、StatementIntakeTest、LedgerConcurrencyTest：关闭/pending/posted、退款冲减、并发额度、分类/锁及后续改动保护。通过。 |
| A03-7 | StatementParserTest、XlsxRowsTest、PdfSourceTest：BOM/GB18030、显式字段映射、错误行、公式、文件和行数上限、PDF 提取证据；250f76ab3 双导入路径互斥，与原 PdfImportTest 一并回归。通过。真实国内银行格式依实际账单列名由通用模板配置，不宣称未经验证的专用银行格式。 |
| A03-8 | SourceReviewTest、StatementIntakeTest、StatementReconciliationsControllerTest：原子整批撤销、共享来源与人工修改冲突、对账撤销前后精确指纹、保留原银行交易。通过。 |
| A03-9 | ProviderSyncStatusTest、ProviderCaptureTest、ProviderCaptureJobTest、原 SyncTest/ProviderImportAdapterTest：模拟 401/429/超时、脱敏诊断、取消和迟到完成防护、重复采集；实际外部银行请求/撤销凭证未执行，审查原 provider adapter、Sync 状态/取消、回调与 Abroa capture 的权限、日志字段及幂等边界；通过阶段口径。无真实银行连通性承诺。 |

末轮审查新增的实际问题均已处理：PDF 双路径入账风险（红测 133 runs/1 failure，250f76ab3 修后 133/133）；并发入账唯一键冲突（7d7c3a58d 红测、03f8a88d6 修后 136/136）；原 OIDC 模拟数据缺已验证字段（244 runs/2 errors，db7889c34 修正夹具并增加 issuer 断言，未放松认证）。

| 实测套件 | 结果 |
|---|---|
| P1/P0.5 行为、权限及并发 | 136 runs, 764 assertions, 0 failures, 0 errors, 0 skips |
| 上述用例 + 9 个原认证相关测试文件 | 244 runs, 1364 assertions, 0 failures, 0 errors, 0 skips（含前述136，不重复计数） |
| 原 Sure 相关回归（18 文件） | 964 runs, 3287 assertions, 0 failures, 0 errors, 0 skips |
| P1 API 请求规格 | 29 examples, 0 failures |
| 数据库迁移和新库初始化 | 7/7；此前生成 schema 新库实际加载和回归通过，本轮无 schema 改动 |
| OpenAPI 全量生成 | 514 examples, 0 failures, 89 文档专用 pending；dry-run，不计入行为用例 |

总计 1237 个独立运行测试（244+964+29），4651 次 Minitest 断言；0 failures、0 errors、0 skips（OpenAPI dry-run 的文档专用 pending 不计入）。原 P0 环境/部署全量审计与后续部署联调不在 P1 签收范围。

日志目录：D:\开发\Abroa\.p1-env\logs；p1-final-review-before.log、p1-final-provider-concurrency-before.log、p1-auth-regression-before.log、p1-final-review-minitest.log、p1-round2-minitest.log、p1-final-review-rspec.log、p1-original-regression.log、p1-openapi-generate.log。测试源清单 p1-test-files.txt，验收代码快照 acceptance-sha.txt。

结论：P1.1–P1.6 在上述阶段开发验收口径下签收为 VERIFIED。未承诺实际第三方网络可用性；真实服务部署后另行联调。P2 业务开发尚未开始，后续阶段保持 PLANNED。
