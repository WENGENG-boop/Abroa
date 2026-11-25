# Abroa P4.5 / A14 与 P1–P4 联合复验（2026-11-25）

验收业务代码 SHA：`0f0d101dc`（`abroa/development`）。本文件补充此前的 `P4_BACKEND_ACCEPTANCE.md`，不改变旧冻结镜像 `121519198`。仅在 D 盘隔离 WSL、PostgreSQL/Redis 和新 Docker Compose 项目中执行；P2/P3 冻结环境、生产账户和真实银行未修改。

## 一、验收结论

**P4.1–P4.5 后端与当前业务 SHA 联合验收：VERIFIED（范围受限）。** 最新 Git SHA 的原版 Rails 全量回归 **19,271 runs / 117,768 assertions / 0 failures / 0 errors / 10 skips / exit 0**。日志：`D:\开发\Abroa\.p4-env\logs\a14-full-acceptance-20261125T120802Z.log`；隔离运行 561.7 秒。Brakeman：0 active security warnings，8 historical ignored / exit 0；日志 `D:\开发\Abroa\.p4-env\logs\weo-p4-brakeman-20261125T120815Z.log`。

A14 已提交的新增测试（`0f0d101dc`）：`test/models/abroa/ai_model_gateway_local_endpoint_test.rb` 和 `test/models/abroa/ai_financial_assistant_test.rb`。专项复验 **40 tests / 275 assertions / 0 failures / 0 errors / 0 skips / exit 0**，日志 `D:\开发\Abroa\.p4-env\logs\a14-reverification-20261125T120515Z.log`。包含真实 TCP/HTTP 回环兼容端点与 Rails API 端到端，以及真实 PostgreSQL 双会话并发。

## 二、原提示词 A14 十一项逐项证据

| 要求 | 结果 | 核查说明 |
|---|---|---|
| 模型模拟响应 | PASS | 确定性固定响应和 TCP/HTTP Chat Completions 200；请求包含 Bearer、model、max_tokens；实际 Rails Controller 链路 |
| 建议拒绝 | PASS | 拒绝后预算、费用、余额不变；已确认提案不能重新拒绝 |
| 确认执行 | PASS | 独立人工确认 token 与资源版本校验，只有白名单预算/费用/虚拟资金池修改能生效 |
| 重复确认 | PASS | token 重放拒绝，重复 execute 幂等；真实 PG 双连接只接受一次 |
| 过期确认 | PASS | 提案过期和状态变化拒绝执行 |
| 并发版本冲突 | PASS | 双 PG session 同时确认只有一次成功，发生资源版本变化时旧提案拒绝 |
| 权限撤销 | PASS | 家长 Grant 实时撤销后 HTTP 200→404，不泄露学生敏感账务 |
| 恶意导入文本 | PASS | 银行描述作为低信任数据，不能转成指令或账务操作 |
| 工具越权 | PASS | 旧 Sure AI/MCP 写工具不能绕过 token；bank_transfer、pay_invoice、execute_shell 等操作不在执行白名单 |
| 密钥泄露 | PASS | Provider Key 加密/遮罩、HTTP 401 错误脱敏；真本地 API 不输出伪 Key |
| 模型故障 | PASS | 401、302 重定向、非法 JSON、Timeout 与 length 截断标记明确处理 |

禁止真实银行付款、自动变更真实银行余额、执行任意系统命令；仅在隔离账本上用人工确认执行允许的财务规划操作。

## 三、最新 SHA 独立 Docker 验收

新环境：`D:\开发\Abroa\.p4-head-stage`；镜像 `abroa-p4-overlay:0f0d101dc`，构建网络关闭，依赖检查通过，镜像 SHA-256：`474fc23f37c6ae7d58cbc01b7e39732c1ea2d16d44e98451aed7b8fcd0c8e4a4`。
- 构建日志：`logs/head-stage-build-20261125T122157Z.log`，`HEAD_STAGE_BUILD_EXIT=0`。
- Web 仅监听 `127.0.0.1:3046`；独立 PG、Redis、Web、Worker；所有 P4 迁移 up、健康检查 HTTP 200。
- 真实 HTTP/合成账本：应收应付/退款、预测、通知、私有导出、AI 提案确认与补偿、Grant 撤销 200→404 均通过。
- 五项 Sidekiq Cron 首轮及 Worker 重启后各 5 项完成。日志：`logs/head-stage-acceptance-20261125T122541Z.log`，`HEAD_STAGE_ALL_CHECKS_PASSED sha=0f0d101dc` / exit 0。
- 新库加密回填 v14 dry-run 和真实 apply 均 failed_count=0：2 users、2 API keys、1 AI model provider；版本验证与 Web/Worker 重启 HTTP 200。日志：`logs/head-v14-encryption-upgrade-20261125T122734Z.log`，`HEAD_V14_BACKFILL_AND_RESTART_PASSED` / exit 0。

## 四、历史数据升级

新环境 `D:\开发\Abroa\.p4-head-upgrade` 使用**已有 P3 测试库的只读 dump** 恢复新 PostgreSQL，未写回 P3 源；原/新记录数完全一致。运行最新 `0f0d101dc` 镜像、P4 schema 升级、旧项目和 Grant 读取、v14 回填及 Web 重启健康检查均通过。日志：`logs/head-p3-upgrade-20261125T122839Z.log`，`HEAD_P3_TO_P4_UPGRADE_ALL_CHECKS_PASSED sha=0f0d101dc P3_source_modified=false` / exit 0。

## 五、全部 10 项 skipped 的准确归属

使用 `--verbose` 在原版独立测试库复跑相关文件：69 runs / 805 assertions / 0 failures / 0 errors / **10 skips**，日志 `D:\开发\Abroa\.p4-env\logs\fix-20261125T122215Z-229449.log`。分别为 Sure AutoSync 暂禁用 2、i18n 检查暂禁用 4、需单独设置 `DAILY_USAGE_REDIS_TESTS=1` 的 Redis 集成 1、`DATABASE_URL` 环境使配置检查跳过 1、API 基类抽象测试 1、Sure 消息重试待调试 1。它们均非 A10–A14 新增专项；**不作为已通过测试，不代表功能已验收**。

## 六、保留限制

此前 rswag OpenAPI 646 examples / 0 failures / 89 pending 为**历史文档生成证据**；本次没有修改路由，89 pending 仍为文档样例而非可替代业务验证。8 条 Brakeman historical ignored 不等于独立第三方安全审计。

外部真实银行/付款、第三方 SMTP、Google OIDC、公开生产部署、第三方对象存储、超长 393216 Token 实际完整输出、P5–P8 前端和未来功能不在本次后端验收范围。之前真实 WEO 接口短响应联调已单独记录，**不将其等价为 384K 输出压力或长期可靠性验证**。

此签收只覆盖最新业务代码 `0f0d101dc` 及列出的隔离测试；保留原始环境与原日志，不修改生产财务数据。
