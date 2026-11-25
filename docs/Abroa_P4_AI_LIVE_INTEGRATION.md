# P4 A14 外部模型集成补充记录（2026-11-25）

本记录属于 P4 正式冻结后追加的网关兼容性修复与验证，不追溯改变冻结业务提交 `121519198` 的验收范围。仅在 D 盘的独立测试与预生产环境执行；不包含公网生产部署、持久密钥录入或真实财务写入。

- 用户本机手动向 `https://api.weo.asia/v1/chat/completions` 发起 `deepseek-v4.1-flash` 请求：HTTP 200，耗时 3563 ms，回复 `PONG`，输入 36、输出 15 tokens。此项证明 WEO API 和模型可用，不代表 Abroa 端到端通过。密钥未记录到文档或仓库。
- P4 Docker 容器原始解析 `api.weo.asia` 为 Mihomo Fake-IP `198.18.2.62`，按网关 SSRF 防护规则必须拒绝。Google/Cloudflare DoH 当日均查询到 `47.251.108.221`；仅在额外 Compose 文件 `D:\开发\Abroa\.p4-stage\compose.weo-model-probe.yml` 为测试容器添加临时 hosts 映射，保留 TLS、公共地址校验和证书验证。该静态 IP 映射不是生产方案，需随 DNS 变化更新；正式部署应配置不返回 Fake-IP 的真实 DNS。
- 外部 HTTP 401 集成测试暴露原 A14 `AiModelGateway::Timeout` 与 Ruby `Timeout` 名称冲突：异常处理时 `Timeout::Error` 错误解析为自定义类的常量，导致 `NameError`，掩盖 `ModelFailure`。修复为 `::Timeout::Error` 并显式 `require "timeout"`。
- 先写失败测试：22 tests / 123 assertions / 2 failures（均为上述 `NameError`）。修复后 22 tests / 123 assertions / 0 failures / 0 errors / 0 skips。包括拒绝响应、超时、非法 JSON、正确 Chat Completions 成功结构及已有财务助手行为。修复记录位于 `D:\开发\Abroa\.p4-env\logs\weo-gateway-green-20261125T101147Z.log`。两个变更文件 RuboCop 0 offenses，`D:\开发\Abroa\.p4-env\logs\fix-20261125T101303Z-3013.log`。
- P4 隔离预生产 Web `127.0.0.1:3044` 健康，容器 IP `47.251.108.221` 通过 `AiModelGateway.resolve_public_ips!`；无效测试密钥由真实 Web 容器发往外部网关后正确获得 `AiModelGateway::ModelFailure`（预期失败），不再产生 `NameError`。证据 `D:\开发\Abroa\.p4-stage\logs\weo-integration-network.log`、`weo-invalid-key-gateway.log`。代码热修复在 WEO 专用 Compose 覆盖中以只读文件挂载注入，未重建或改写 P4 冻结镜像，亦未修改 P2/P3 环境。
- 真实密钥经 **Abroa 网关内部** 返回 200 的成功路径仍待手动验证（用户本机已验证的是直接 API）：在 Windows PowerShell 交互运行 `D:\开发\Abroa\.p4-env\tmp\weo-abroa-model-check.ps1`，隐藏输入密钥，经 stdin 传入隔离容器，不持久化、不传入进程命令参数。该脚本输出 `ABROA_GATEWAY_LIVE_TEST_PASSED` 方算此项成功。
- 此次追加修复执行的是定向 A14 测试与静态检查，**没有重跑 19,253 项完整 P1–P4 回归**，也不构成新的整体验收签字。生产部署前须在最终发布镜像复跑相应测试，并解决 Fake-IP DNS 环境问题。
