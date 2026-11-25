# Abroa P4.5 / A14 按原始提示词全量验收（2026-11-25）

**验收口径**：本报告逐条执行原 P4.5/A14 要求，而不以真实模型能返回 `PONG` 代替业务验收。所有自动化均在 D 盘独立 WSL/PostgreSQL/Redis 测试环境执行，未连接真实银行账户、未自动发起付款、未调用任意系统命令。业务提交 `d4334f3be`（`P4.5: secure user AI models and confirmed financial operations`）保留；本报告及新增验收测试另行提交 `P4.5:`。

## 必测场景矩阵

| 原始要求 | 结果 | 证据（test/models/abroa/ 与 test/controllers/api/v1/abroa/ 下） |
|---|---|---|
| 模型模拟响应 | PASS | `ai_financial_assistant_test.rb`：只读模型替身；`ai_model_gateway_test.rb`：OpenAI Chat Completions 正常响应。新增 `ai_model_gateway_local_endpoint_test.rb` 通过真实 TCP 监听、实际 HTTP 请求/响应和确定性 JSON 验证 |
| 建议拒绝 | PASS | `ai_financial_assistant_test.rb`：rejected proposal and missing confirmation cannot change budget；确认后不可再拒绝，状态一致 |
| 确认执行 | PASS | confirm then execute updates only the intended budget once and logs it；fee waiver 与 pool allocation 均需 token+版本确认 |
| 重复确认 | PASS | confirm then execute 测试再次提交同一确认 token 被拒绝；两次 execute 幂等；真实 PG 并发两 session 仅一个 confirm 成功 |
| 过期确认 | PASS | old proposal, stale resource version or another tenant cannot execute：过期 token 拒绝；执行前也检查到期时间 |
| 并发版本冲突 | PASS | `ai_proposal_concurrency_test.rb`：双真实 PostgreSQL session 竞态，同一提案不同版本确认只有一次成功，重复执行只发生一次账务调整；资源版本变更拒绝旧提案 |
| 权限撤销 | PASS | explicit parent AI scope never receives bank entry IDs or private debt details：撤销 P3 Grant 后父母侧不再可读；跨家庭访问拒绝，Provider owner/family 独立 |
| 恶意导入文本 | PASS | injected imported transaction text is data and cannot execute arbitrary actions：恶意导入描述作为低可信数据进入提示词，不作为系统指令执行，账本不变 |
| 工具越权 | PASS | legacy Sure AI write tools cannot bypass a confirmation；the AI registry and MCP share the restriction；本次新增真实本地 API/模型链路确保未向模型传入可执行 tools；非白名单操作拒绝 |
| 密钥泄露 | PASS | custom OpenAI-compatible API key is encrypted and masked；本地真实 HTTP 401 返回体含伪密钥时网关返回通用安全错误；Provider/API 公开字段与错误均无明文密钥 |
| 模型故障 | PASS | model failure and timeout are recorded；Gateway HTTP 401、Net::ReadTimeout、非法 JSON；本地实际 HTTP 401、302 外部跳转拒绝、非法 JSON；上限截断标为 `incomplete` |

## 禁止行为与边界

- `Abroa::AiProposalAdapter::EXECUTABLE` 白名单严格为 `budget_update`、`fee_adjust`、`pool_allocate`；新增回归明确断言 `bank_transfer`、`execute_shell`、`run_system_command`、`pay_invoice`、`update_account_balance` 均不可生成提案。
- `AiFinancialAssistant` 只向模型发送授权汇总，不提供工具列表；不由模型执行写入。任何白名单规划变更需用户单独确认 token、有效期、乐观锁版本/状态摘要；重复执行无额外生效。
- 资金池分配变更仅修改内部额度/准备金，不产生银行付款、不直接修改 `Account.balance` 或生成真实付款 Entry；测试覆盖了前后数值。费用减免与预算变更不是银行支付。
- 导入银行描述、用户询问和模型生成文本均不能执行任意系统命令；现有网关请求 JSON 仅含 `model/messages/temperature/max_tokens/stream`，无 shell、payment、function/tool execution 指令接口。
- 云端坚持 HTTPS + 公开 DNS + SSRF 禁止重定向；自托管环回端点仅在 `self_hosted?` 且 `ABROA_AI_ALLOWED_LOCAL_ENDPOINTS` 完整 URL 精确白名单时可使用；所有本地测试监听 `127.0.0.1` 的动态端口，测试结束关闭套接字。

## 无真实凭证时也能验收

新增 `test/models/abroa/ai_model_gateway_local_endpoint_test.rb`，无需 WEO/DeepSeek 等真实凭证，使用固定测试用伪 Key、Ruby `TCPServer` 模拟 HTTP Chat Completions；有**真实 TCP/HTTP 往返**而非仅 stub `AiModelGateway.chat`。分别验证：

1. 200 正常正文、usage、模型 ID、header Bearer 及 `max_tokens`；
2. 401 安全错误与伪密钥不泄露；
3. 302 指向 metadata IP 拦截，不追随外链；
4. 200 非法 JSON 被统一映射为 ModelFailure；
5. `finish_reason=length` 正文标为不完整；
6. 真实 `AiFinancialAssistant.answer_for!` 经过本地兼容 HTTP 且预算、Entry 不变，不能获得工具列表；
7. 使用 `X-Api-Key` 经真实 Rails API Controller → 财务助手 → 本地 HTTP 服务，随后读取 usage；核对返回内容、只读性与密钥脱敏。

最新专项复验日志：`D:\开发\Abroa\.p4-env\logs\a14-reverification-20261125T120515Z.log`，**40 tests / 275 assertions / 0 failures / 0 errors / 0 skips / exit 0**，内含真实 PG 两会话并发。新增两个测试文件相关 RuboCop 检查：`D:\开发\Abroa\.p4-env\logs\fix-20261125T120533Z-192022.log`，0 offenses。原始专项验收：`20261125T081250Z-109900.log`（21/159/0）；原始 PG 并发验收：`20261125T081344Z-111028.log`（1/7/0）。

## 外部事项与限制

- **真实第三方模型不作为 A14 准入条件**。之前 WEO `deepseek-v4.1-flash` 已另行完成直接 HTTPS、Abroa Gateway 和真实财务 API 的联调，相关记录见 `Abroa_P4_AI_FINAL_VALIDATION_20261125.md`、`Abroa_P4_AI_HIGH_OUTPUT_20261125.md`。这些测试使用的真实模型仅作为附加集成证据，不混入本地确定性 A14 结果，也不能等价为长期可靠性承诺。
- 此次不做真实银行支付/余额写入实验（该能力本就禁止）；本地模型测试运行在隔离 WSL Rails 环境，非公开生产部署；Docker stage / P2 / P3 冻结镜像和生产资金库不受影响。
- P5–P8 前端、真实银行、生产发布、极限 384K 输出、第三方安全审计不属于此 A14 后端准入签收范围。完整 Rails 全量回归、Brakeman 和 OpenAPI 检查结果在签收前附加，不能用本报告 40 个专项测试替代全量回归。
