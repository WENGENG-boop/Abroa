# P1–P4 独立验收缺陷、修复与例外

基线：38adcae14cff6d04987b7e1e39745c6467899c8d；2026-11-26。下列按独立复现证据记录，不将历史报告结论抄作新发现，也不把“未发现新的业务错误”解读为无风险。

| ID | 阶段 | 严重度 | 本轮复现和根因 | 已采取的措施 | 实际状态/证据 |
|---|---|---|---|---|---|
| ENV-001 | P1–P4 | 低 | 测试归档未附 .git；Sure.commit_sha 调用 git rev-parse HEAD 时重复输出 fatal:not a git repository | 定位 config/initializers/version.rb:11；在第二遍独立测试执行环境通过 GIT_DIR 与 GIT_WORK_TREE 指向 D 盘现有真实只读提交信息，不更改源码/归档 | 首次完整测试 0 fail；第二遍 verbose 日志证明 SHA 匹配，待末尾结果 |
| ENV-002 | P4/P3→P4 | 低 | 升级容器重启后立即 curl，连接被 reset；Web 仍处于就绪过程 | 增加最多 60 次/2 秒的健康等待并重试；再次检查容器和 /up 后 PASS | docker-b-restart-verification 日志，环境脚本修复，无业务代码变更 |
| SEC-001 | Sure 基线 | 需独立审计 | Brakeman active=0，但旧忽略文件有 8 项，其中 2 项标记 High (account_id 可赋值) | 检查 TradesController 创建入口通过 family.accounts.writable_by(owner).visible.find，对转账目标再检 writable；RecurringTransactionsController 委托 DeclaredBill 对目标校验 | 忽略原因需要逐项评估，不归入活跃 0 项；见 SECURITY_REVIEW |
| LINT-001 | P2 | 低/阻塞规范签核 | RuboCop 全仓 3,849 文件有 14 条 Layout/SpaceInsideArrayLiteralBrackets | 已定位仅 20261124140000_create_abroa_study_projects.rb、20261124140100_create_abroa_planning_operations.rb；项目数据库文档禁止直接改历史 Migration，因此未通过覆盖冻结代码掩盖告警 | OPEN；static 日志，RUBOCOP_EXIT=1 |
| FRONT-001 | Sure 前端基线 | 范围审查 | Biome lint 0；style:check 82 errors / format:check 77 errors | 把依赖安装、npm 缓存和 TEMP 限制 D 盘；隔离归档不自动写回产品 UI；须区分 P5–P8 未开发的新 UI 和本轮 P1–P4 范围 | OPEN，frontend-node-check-20261126.log |
| TEST-001 | 全阶段 | 需解释 | 本轮 10 skips、专项 1 skip | 已启动 full --verbose 实际重新运行，以测试用例具体名称逐项分类；未补证前不得将 skips 计入通过 | OPEN，rails-verbose-git-fixed 日志 |
| API-001 | Sure 基线 | 低 | API 检查通过但 --compliance 指出 financekit_spec OAuth 及 transfers/transactions rswag 含断言 | 记录为原 Sure 既有规范项；未擅自修改非 Abroa 行为 | REVIEW，static 日志 |

本轮至今未复现新的 P1–P4 业务断言失败或金额/越权缺陷，因而没有通过删测试、修改预期或减弱权限制造虚假修复，也未制作虚构的“业务修复 Commit”。如后续验证发现功能缺陷，必须先补失败用例、修代码、专项/跨阶段/全量回归，再创建对应阶段的独立提交。

两份原有未跟踪文件 Dockerfile.abroa-acceptance 和 bin/abroa-p1-syntax.rb 均保留，不纳入验收提交。

## 续验缺陷与验证闭环（2026-11-26）

- **ENV-003 / 本轮测试设备 / 低 / 已解决**：为消除 Git HEAD 提示错误而导出的全局 GIT_DIR 污染了原 Sure ReleaseWorkflow 测试用例创建的临时 Git 仓库；第二轮一度出现 11 failures。根因不是产品代码，补救是仅在 WSL D 盘隔离测试源码目录创建本地 Git 元数据，并从执行环境移除 GIT_DIR / GIT_WORK_TREE。复测 ReleaseWorkflow 12 runs / 399 assertions 全通过，完整 Rails 19278 / 117814 / 0 failures / 0 errors 再次通过。原仓库 Git 配置文件无残留锁。
- **A14-TEST-001 / P4.5 / 测试覆盖缺口 / 已修复**：原本 A14 本地兼容 HTTP 测试缺 500/503 响应脱敏直接覆盖。新增本地真实 TCP HTTP 500/503 回归，用合成 API Key 检查异常不能泄露；8 runs / 75 assertions 全通过，针对测试单独提交 7cc66fec92b1d786c2f7e44ac38118e15c0eefc1。测试增强不修改真实模型或账务代码。
- **TEST-001 / 本轮 skip 结案分类**：原 10 个 skips 中两个有可运行前提，已单独解除条件并执行通过（Redis fork 测试 1/36，DB config 测试 1/2）。另 8 个为原 Sure 明确禁用或占位：4 I18n、2 AutoSync、1 Messages 重试、1 BaseController 方法占位；只记录范围外，不计作通过。
- **SEC-001 / Sure 历史忽略项 / 复核证据增强**：账户可写性边界补跑 93 runs / 447 assertions 全通过；Brakeman 原本 8 ignored（其中 2 High）仍须按历史基线保留，不得改写为 0 ignored。
- **LINT-001 仍 OPEN**：两份已应用的 P2 历史 Migration 共 14 个 whitespace lint，不在违反“不要更改历史 Migration”规则的前提下直接改写迁移；尚不能将全仓 RuboCop 报告为 0。
