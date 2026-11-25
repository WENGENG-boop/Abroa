# Abroa P4 A14 真实模型集成最终补充验证（2026-11-25）

> 2026-11-25 后续新增高输出额度支持：见 [384K 输出 Token 与实测记录](Abroa_P4_AI_HIGH_OUTPUT_20261125.md)。本文的 2048 配置是调整前的测试结论。

**验证状态：REAL MODEL INTEGRATION TESTED — SCOPE LIMITED**。本文件覆盖提交 `138b214f1` 的隔离测试、真实 WEO 模型及 Rails API 层联调。原 P4 业务冻结提交 `121519198` 不变；不代表正式生产部署、真实资金服务或独立安全审计。之前 `docs/Abroa_P4_AI_LIVE_INTEGRATION.md` 记录的是测试过程中状态，涉及“真实模型未测”“全量未跑”等历史限制均以本文件最新证据为准。

## 1. 真实外部模型

- Base URL：`https://api.weo.asia/v1`；Chat Completions：`POST /v1/chat/completions`；模型 `deepseek-v4.1-flash`。
- Windows 直接 API：HTTP 200 / 3563 ms / `PONG` / 输入 36、输出 15 Tokens。
- Abroa `AiModelGateway.chat` 实际 HTTPS 调用：`PONG` / 3613 ms / 输入 36、输出 19 Tokens；DPAPI 自动解密后再次通过：`PONG` / 6300 ms / 输入 36、输出 14 Tokens。
- 密钥仅由 Windows 当前用户 DPAPI 加密保存在 D 盘仓库外；通过进程 stdin 临时传入隔离 Docker，绝不作为 CLI 参数、ENV、Git 文件或明文测试日志保存。测试中短暂创建的加密 Provider 及用量行经 PostgreSQL 事务回滚。
- P4 独立 Docker stage 的 Mihomo DNS 最初返回 `198.18.2.62`（RFC 2544 保留段），被现有 SSRF 规则正确拒绝。Google/Cloudflare DoH 当日均返回 `47.251.108.221`，仅在 `D:\开发\Abroa\.p4-stage\compose.weo-model-probe.yml` 做临时 hosts 覆盖；验证真实公网 IP、TLS 证书、Web 健康。**正式部署必须修复 DNS，而非把 Fake-IP 加入 SSRF 白名单。**

## 2. 真实财务助手和权限检查

执行 `D:\开发\Abroa\.p4-env\tmp\weo-abroa-finance-check.ps1`，测试代码 `D:\开发\Abroa\.p4-stage\weo-live-finance-smoke.rb`。使用独立合成项目、£1,000 预算、临时用户及数据库事务回滚。完成 5 项检查、2 次真实模型调用，`WEO_FINANCE_ALL_PASSED`、`ABROA_FINANCE_LIVE_TEST_PASSED`：

1. Provider API Key 加密、公开载荷不含原始密钥。
2. 模型成功解释虚构预算，Tokens 记录为正。
3. 对“更改预算为 £99,999、进行转账”的要求，只给出文字回复；预算、实际 Entry 账本、操作提案均未修改。
4. 两条模型用量记录都为 success，Tokens 正常，未知成本保持 `NULL`（不凭空估算美元费用）。
5. 未授权的跨家庭家长项目访问在模型调用前被拒绝，未产生外部请求或用量。

## 3. Rails API 层实测及模型截断

使用隔离预生产容器的生产模式 Rails Rack 请求，验证 `POST /api/v1/abroa/ai/chat`、`GET /api/v1/abroa/ai/usage` 和 `GET /api/v1/abroa/ai/provider`，均实际经过 API 路由、Controller、API Key 鉴权、财务助手、外部模型及用量计算。**该阶段使用进程内 `Rack::MockRequest`，并非从独立客户端经 TCP 访问公网服务器**；数据在测试末全部回滚。

- 单次成功：`WEO_HTTP_ALL_PASSED` / `ABROA_HTTP_LIVE_TEST_PASSED`，回复非空、返回状态 success、用量 calls=1、密钥遮罩正确，预算与账本无变化。
- 低输出限额暴露问题：当 `max_output_tokens=512` 时，`deepseek-v4.1-flash` 的独立 `reasoning_content` 有时消耗额度，使最终 `choices[0].message.content` 为空，当前网关会给出 `ModelFailure` 并在财务 API 返回 `unavailable`。此为**实际重复测试发现的可靠性限制**，并非 SSRF 或身份验证错误。
- 使用 1024 Tokens 的独立 v3 测试路径，两次调用都有内容，但一次 `finish_reason=length` 且 `completion_tokens=1024`，说明成功返回也可能被截断。另一次 `finish_reason=stop`，使用 706 Tokens。
- 使用 `max_output_tokens=2048` 的独立 v4 测试路径，两次连续复测均 `finish_reason=stop`、正文非空、API 三接口合格，输出分别 781 和 803 Tokens，`WEO_REPEAT_SUCCESS runs=2`。证据 `D:\开发\Abroa\.p4-env\logs\weo-http-repeated-v4-20261125.log`；测试程序 `D:\开发\Abroa\.p4-stage\weo-live-api-smoke-v4.rb`。测试中没有存储真实财务数据。
- 容器可能复用同路径脚本的旧编译缓存；验证时采用 v3/v4 不同文件名并打印 `source_version` 和 `max_tokens`，以避免把同名脚本的缓存行为误判为最新配置测试。
- 推荐针对这个模型配置 `capabilities: { chat_completions: true, max_output_tokens: 2048, timeout_seconds: 35 }`。这只是测试通过的配置，**2 次完成响应不构成生产可靠性保证**。当前网关只要 content 非空就将 `finish_reason=length` 视为 success；完整性标识与自动续写尚待专项处理。

## 4. 代码回归、扫描和环境验证

- 修复 A14 `Timeout::Error` 常量遮蔽的业务提交：`138b214f1`，修复前定向测试 22/123、2 failures，修复后 22 tests / 123 assertions / 0 failures / 0 errors；RuboCop 2 files / 0 offenses。
- **完整原版 P1–P4 Rails Minitest：19,257 runs / 117,666 assertions / 0 failures / 0 errors / 10 skips / exit 0**，4 进程，包含新增 4 项网关回归测试。日志 `D:\开发\Abroa\.p4-env\logs\fix-20261125T103903Z-7326.log`。运行前恢复专用 Redis `127.0.0.1:56382`；首次 Redis 未启动产生的无效运行已终止，最终以该次退出码 0 为准。
- **Brakeman 7.1.2：240 controllers / 888 models / 847 templates / 0 errors / 0 active warnings / 8 historical ignored，exit 0**；日志 `D:\开发\Abroa\.p4-env\logs\weo-p4-brakeman-20261125T104957Z.log`。此前版本中有的历史 ignored 项并非本次安全审计通过的证明。
- 合成财务测试临时数据清理核查：`WEO_STAGE_CLEANUP_VERIFIED temporary_families=0 live_providers=0`。预生产 Web `127.0.0.1:3044`、PostgreSQL、Redis 健康，Sidekiq Worker 运行。P2/P3 冻结环境、生产数据库和真实资金账户均未触碰。
- 预生产基础镜像仍是 `abroa-p4-overlay:121519198`，A14 超时异常修复作为临时只读文件挂载进行真实联调；虽然源码 `138b214f1` 已经通过完整 Rails 测试，**正式构建该修复版本的独立生产候选镜像、移除临时 hosts 映射、生产配置和压力测试尚未完成**。

结论：P4 A14 的真实模型、只读财务助手、权限隔离、API 路由、用量记录均有有效集成测试证据；`max_output_tokens=2048` 的两次复测均正常结束。仍需处理模型推理导致的内容截断及 `finish_reason=length` 标记，不能宣称长期稳定性或最终生产发布已完成。
