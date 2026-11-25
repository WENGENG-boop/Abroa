# Abroa A14 — 大输出 Token 限额与真实 WEO 验证（2026-11-25）

本改动是 P4 验收后针对 AI 模型输出能力的增量兼容修复，保留 A14 只读与 SSRF 防护，不改变 P4 冻结业务版本和 P2/P3 环境。**上下文窗口、输出额度、HTTP 请求体限制、财务助手单条问题上限是四个不同维度。**

## 模型依据与网关实测

- DeepSeek 官方文档（https://api-docs.deepseek.com/quick_start/pricing/）和阿里云 `deepseek-v4.1-flash` 规格（https://www.alibabacloud.com/help/en/model-studio/deepseek-v4-1-flash）公布：**1,000,000 Tokens 上下文**和**393,216 Tokens 最大输出**，不是千万 Tokens。
- WEO 网关 `https://api.weo.asia/v1` 对 `deepseek-v4.1-flash` 的实际调用（合成 `PONG` 请求，已保存的 DPAPI 密钥）：`max_tokens=16384`、`131072` 和 `393216` **分别返回 HTTP 200**。仅证明网关接受这些参数，并不代表真实生成 384K Tokens 的流式长回答。
- 生产模式 Abroa 隔离容器经过 `AiModelProvider.capabilities!` 和 `AiModelGateway.chat` 使用 `max_output_tokens=393216` 真实连通 WEO：`WEO_ABROA_MODEL_HIGH cap=393216 status=success finish_reason=stop incomplete=false output_tokens=13`、`ABROA_HIGH_OUTPUT_LIVE_TEST_PASSED`。脚本 `D:\开发\Abroa\.p4-env\tmp\weo-abroa-high-output-check.ps1`，仅将密钥经 stdin 传入，未保存明文。

## Abroa 业务代码变更

- `AiModelProvider`：默认 `max_output_tokens` **1024 → 16384**；允许用户单独配置 **32–393216** Tokens；默认超时 **20 → 120 秒**，允许配置 **5–600 秒**。现有 Provider 已保存的配置**不会被自动覆盖**，需通过 `PATCH /api/v1/abroa/ai/provider` 用乐观锁 `lock_version` 手动更新。
- `AiModelGateway`：不再使用原 12,000 字节每条消息、32,000 字节请求体、2 MiB 响应、15,000 字节模型正文的旧限制。现分别调整为单条消息 **8 MiB**、整个 JSON 请求 **8 MiB**、整体上游响应 **32 MiB**、模型正文 **16 MiB**，仍检查大小，不开放无限内存消耗；保持 TLS、固定公开 DNS IP、禁重定向和无代理策略。
- 上游 `finish_reason="length"` 且正文非空时，Gateway 返回 `incomplete: true`，财务回答 API 的 `data.incomplete` 同步为 true，避免截断未提示。无截断则 false；截断不自动续写。
- 财务助手的 `MAX_QUESTION_BYTES=3000`、业务上下文（授权账本摘要、预算、财务报告）及访问权限仍保持原有安全限制；这项修改**不会自动让财务问答输入支持 100 万 Token**。通用长上下文、多轮完整聊天与超长回答的流式/异步处理尚未实现。
- 大额度意味着更高潜在 Token 成本和更长响应时间；同步 HTTP 即使设置最大超时 600 秒，也不能保证一次输出 384K Tokens。WEO 可能对其他模型实施不同上限，应由用户按模型配置。暂不声明大规模输出/全长上下文已经被验证。

## 验收证据

- 先写失败测试：旧版在默认输出和较长输入测试中失败；新代码完成 Provider 上限/默认/非法值、API 控制器写入与越界拒绝、网关高 Token 透传、长请求与长回复、超时和截断标记、财务只读行为的覆盖。
- 定向 Minitest 完成后以日志 `D:\开发\Abroa\.p4-env\logs\weo-gateway-green-20261125T111206Z.log` 为基线（后续修订详见验收输出）；6 份相关代码与测试文件经 RuboCop 检查 0 违规，日志 `D:\开发\Abroa\.p4-env\logs\fix-20261125T111240Z-81178.log`。
- **最终完整 P1–P4 Rails 回归（代码提交 `e92483ecb`）：19,263 runs / 117,696 assertions / 0 failures / 0 errors / 10 skips / exit 0**。证据：`D:\开发\Abroa\.p4-env\logs\fix-20261125T111648Z-90023.log`。本次增加的测试纳入了原有测试集，使用 D-backed WSL 独立 Postgres/Redis 环境。
- **Brakeman 7.1.2：240 controllers / 888 models / 847 templates / 0 errors / 0 active security warnings / 8 historical ignored / exit 0**；日志：`D:\开发\Abroa\.p4-env\logs\weo-p4-brakeman-20261125T111747Z.log`。6 个相关文件的 RuboCop：0 offenses，日志：`D:\开发\Abroa\.p4-env\logs\fix-20261125T111240Z-81178.log`。
- 真实 WEO、HTTP Provider 配置与模拟长内容仅在 D 盘隔离测试环境执行；未修改 C 盘、P2/P3 预生产环境或任何真实账本记录。P4 预生产端仍通过本地临时 hosts 映射绕开 Mihomo Fake-IP；正式部署前需改成真实 DNS，并单独制作/测试新代码镜像。
