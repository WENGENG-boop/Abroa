# Abroa P1–P4 本轮独立全量验收报告

审核日期：2026-11-26。仓库：D:\开发\Abroa\Abroa；分支 abroa/development；本轮原始业务 SHA 38adcae14cff6d04987b7e1e39745c6467899c8d。验收只使用 D 盘隔离数据库、Redis、镜像及合成记录，未接触真实银行、支付或生产账号。保留原有两个未跟踪文件，不清理历史环境、不修改历史 Migration。

**正式状态：NOT VERIFIED（进行中的独立审核，不得作为正式签收）**。原因：全量 10 个 skips 逐项签核、前端现有格式错误的范围归属、两处历史 P2 迁移的 14 个 RuboCop 违规及 A01–A14 逐条断言签核尚未全部完成。任何完整回归通过均不替代独立验收。

## 本轮实际测试（区别于历史报告）

- Rails 完整 Minitest（当前 HEAD 的独立 Git 归档，PostgreSQL 17 + Redis）：**19,278 runs / 117,814 assertions / 0 failures / 0 errors / 10 skips**；exit 0。原始日志：D:\开发\Abroa\.p1-p4-full-20261126\logs\rails-full-20261126T010841Z.log。全量第二遍 verbose（修复只读 Git HEAD 解析）另有独立日志，结果以该日志末尾为准。
- P1–P4 模型、控制器及跨业务专项集合：**496 runs / 2,794 assertions / 0 failures / 0 errors / 1 skip**；exit 0。日志：logs\abroa-focused-20261126T012126Z.log。
- Rswag 独立文档生成：646 examples / 0 failures / 89 pending，exit 0；pending 为文档专项（不得算作 646 个真实行为通过）。生成的 docs/api/openapi.yaml 与原始文件 SHA-256 同为 dc2e5b83896af46498dc7dd1ee80209fb5f6523c49ecd5331d939ed142f3b80d。日志：logs\rswag-20261126T012120Z.log。
- API endpoint consistency 与 --compliance 均 exit 0；同时明确列出 Sure 既有 3 处合规提示：financekit_spec.rb 使用 OAuth、transactions_spec.rb 和 transfers_spec.rb 包含断言。
- Brakeman exit 0，0 活跃警告、8 个原 Sure 历史忽略项（其中两项标为 High，不应混同于“从未存在”）；见安全报告。
- RuboCop 3,849 files inspected，14 offenses，exit 1；全部为两份 P2 历史 Migration 的 Layout/SpaceInsideArrayLiteralBrackets。数据库规范要求不得直接修改历史 Migration，故未越权更改。
- 前端基于 D 盘独立归档的 npm 安装及 Biome：lint=0；style:check=1（82 errors），format:check=1（77 errors），具体见前端日志，未直接批量格式化 Sure 既有代码。

## 按阶段业务验证

P1：身份/资料/地区汇率/账单导入/跨源匹配与隔离，已参与全量和专项测试。当前对数据库约束、测试名及单个需求的验证映射见 P1_P4_FULL_ACCEPTANCE_MATRIX.md；未签核项目保留 NOT VERIFIED。

P2：项目生命周期、账户挂接、预算、虚拟资金池、费用分期、金额精度、幂等与事务审计，已参与 Rails 全量、专项及 Docker 实际 API 验证。资金池为规划记录，不向真实账户转账。两份历史 P2 迁移存在上述代码风格违规。

P3：家长关联、Grant、提议/拒绝及拨款计划/真实收款证据已重跑；冻结业务节点从 Git 核实为 119317b9cb4382d7d9c870ce50aed615148f5739。升级从 P3 合成数据只读备份创建隔离副本，详见迁移报告。

P4：A10 债权债务、A11 预测、A12 通知/Outbox、A13 报表导出、A14 AI 人工确认与补偿均有源码与本轮专项测试。实际 OpenAI 兼容 HTTP 使用测试内部本地 TCP 服务、非第三方真实模型；PostgreSQL 两连接并发测试通过；外部模型、真实 SMTP/OAuth/银行服务未验证，禁止写为 PASS。

## 跨阶段验证及执行环境

- 独立容器 A：从零数据库执行全部 Migration；PostgreSQL、Redis、Web、Worker 健康；HTTP /up 可用；P3 拨款到账 / P4 A10–A14 合成业务、Grant 撤销 200→404、5 类定时后台 Job 及 Worker 重启已执行；自动 Cron tick 另有日志。
- 独立容器 B：P3 stage 只读 pg_dump → 新 P4 库；12 users / 10 entries / 8 projects / 6 relationships / 4 funding plans 在升级前后数量相同，原 P3 源保持不变；加密 dry-run/apply 0 失败；Web/Worker 重启后健康。其后 P4 业务 API 独立复测见专用日志。
- 完整需求追踪矩阵为按当前 PRD 和 A01–A14 重建的 97 行，覆盖代码、API/Job、数据库、测试路径及本轮证据。COVERED-REVIEW 不等于 VERIFIED。

## 排除项及结论

第三方真实 AI、银行接口、支付、Google OAuth、SMTP 外发和生产部署均属于未授权/缺少凭证的外部未验证项；项目 P5–P8 的新前端、管理后台和生产上线不属于 P1–P4。未为这些事项伪造“通过”。在所有逐项缺口解决前，不得提交名为 complete P1-P4 full acceptance and sign-off 的签收提交。

验收原始目录：D:\开发\Abroa\.p1-p4-full-20261126\logs。证据、安全、缺陷、迁移报告与本文件相互独立，可复验。

## 2026-11-26 续验：二次独立回归及逐项 skip 核查

- 在测试快照本地建立独立 Git 元数据（不在真实仓库创建锁文件、不设置全局 GIT_DIR），所有原 Sure ReleaseWorkflow 用例重新通过：12 runs、399 assertions、0 failures；原先 verbose 的 11 failures 均由错误的跨进程 GIT_DIR 导致，已定位并消除，不属于产品缺陷。证据：logs/snapshot-git-release-20261126T020313Z.log。
- 修正后第二轮原业务 SHA 38adcae14 的完整 Rails verbose 回归：**19278 runs / 117814 assertions / 0 failures / 0 errors / 10 skips**，exit 0。证据：logs/rails-verbose-git-fixed-20261126T020351Z.log。
- 2 个可执行的条件性 skip 已在独立环境补跑：UsageRedisTest 原子领取（8 fork 进程，1 run、36 assertions、0 skips）；RecurringTransaction::PipelineTest 配置测试（仅在 DATABASE_URL 未覆盖时可执行，1 run、2 assertions、0 skips）。证据：logs/redis-multiprocess-20261126T020418Z.log、logs/sure-connection-skip-enabled-20261126T020542Z.log。
- 其余 8 个 Sure 基线显式禁用/占位测试：MessagesControllerTest 重试 1；AutoSyncTest 登录自动同步 2；I18nTest missing/unused/normalization/interpolation 4；Api::V1::BaseControllerTest current_resource_owner 占位 1。均未宣称通过，也不计入 Abroa P1–P4 测试通过数，仍属原 Sure 留存的范围外功能风险。
- 真实本地 SMTP 发送：隔离 Docker A 的 Web 进程经 TCP/SMTP 对本地模拟邮件服务器实际投递 1 封；重复执行不会重复发信；邮件不含合成项目名，真实 Sure Entry 数不变。证据：logs/smtp-real-local-20261126T020801Z.log。
- P3→P4 数据证明升级为 **39 张原有表逐行原始记录哈希一致**，含 Abroa 业务表、Sure accounts/entries/families（不以“仅记录数相同”冒充字段完整）。敏感用户字段因加密 backfill 有预期变动，按迁移/解密另外验证。证据：logs/p3-p4-row-fingerprints-20261126T021053Z.log。
- 针对 Brakeman ignored High 的账户引用安全边界补跑 Sure 交易 API 与 DeclaredBill 测试，**93 runs / 447 assertions / 0 failures / 0 errors / 0 skips**。证据：logs/sure-high-ignore-security-retest-20261126T021222Z.log。
- 新增 A14 本地 OpenAI 兼容端点 HTTP 500/503 状态与 API Key 脱敏真实请求测试，独立完整本地端点专项 **8 runs / 75 assertions / 0 failures / 0 errors / 0 skips**，对应独立提交 7cc66fec92b1d786c2f7e44ac38118e15c0eefc1；见 logs/a14-local-5xx-targeted-20261126T021554Z.log。该提交仅修改测试代码，不更改应用 API、数据库和业务执行行为。

最终 HEAD 7cc66fec9 的独立源码快照全量回归尚需以其最终日志末尾退出码为准；未获得结果前继续保留 NOT VERIFIED。

## 最新提交的独立最终全量结果

- 实际源码 SHA：`7cc66fec92b1d786c2f7e44ac38118e15c0eefc1`；独立全新 PostgreSQL 测试数据库 + 隔离 Redis。全量 Rails **19279 tests / 117826 assertions / 0 failures / 0 errors / 10 skips**，exit 0。日志：`D:\开发\Abroa\.p1-p4-full-20261126\logs\rails-final-commit-full-20261126T021735Z.log`。
- 最终静态检查：Abroa 相关 **186 files / 0 RuboCop offenses**；Brakeman **0 active / 8 ignored historical**；API consistency exit 0。日志：`D:\开发\Abroa\.p1-p4-full-20261126\logs\final-commit-static-20261126T022053Z.log`；Brakeman JSON：`D:\开发\Abroa\.p1-p4-full-20261126\logs\brakeman-final-7cc66fec.json`。
- 97 条追踪矩阵：P1 23，P2 30，P3 7，P4 37；全部已有代码/测试文件级定位，但逐需求源码及断言签核仍未逐行完成。方法级证据索引 `docs/P1_P4_METHOD_LEVEL_TEST_EVIDENCE.md`。
- 遗留范围：8 条原 Sure 明确 disabled/placeholder skips（不计通过）；另外 2 条可运行 skips 已单独执行通过。全仓 RuboCop 的 14 个历史 P2 Migration 格式问题与原 Sure 前端 Biome 82 style / 77 format 报错，未以修改历史迁移或降低检查范围制造全仓通过。
- **正式结论：NOT VERIFIED。** 独立业务回归、Docker/SMTP/Cron/加密和原始数据完整性验证通过，但仍未完成全部 97 项需求逐条独立签核，也有上述全仓规范遗留。不能创建“P4: complete P1-P4 full acceptance and sign-off”式误导性签收提交；只能独立提交真实审查报告。

## 基线与 Git 提交追溯

- P1 冻结基线：`66b68eac4`；P2 验收基线：`2f9152daa`；P3 实际冻结业务节点：`119317b9cb4382d7d9c870ce50aed615148f5739`。
- P4 历史安全修复：`9fcc46bc1`；P4 最新业务验收节点：`aae713857`；本轮起点 P4 已签收基线：`38adcae14cff6d04987b7e1e39745c6467899c8d`。
- 本轮新增独立可复验测试提交：`7cc66fec92b1d786c2f7e44ac38118e15c0eefc1`，仅补充 A14 本地 HTTP 500/503 + credential redaction 回归测试；未发现需要改变现有核心业务行为的真实断言失败，历史 11 个 ReleaseWorkflow 失败为隔离 Git 环境污染并已复测。
- 本次报告及矩阵将作为独立**审查证据提交**，其 SHA 应通过 Git 历史查询；不是符合全部条件的正式 sign-off 提交。工作树中 `Dockerfile.abroa-acceptance` 和 `bin/abroa-p1-syntax.rb` 未提交且未删除。
