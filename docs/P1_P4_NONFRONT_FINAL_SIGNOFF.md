# Abroa P1–P4 非前端全量独立验收签收（2026-11-26）

结论：**VERIFIED — 已按用户批准的模拟测试与代码审查口径通过，范围仅限 P1–P4 非前端。**

Git 基线：e5fc2c592dc99f7853bc3c4f09b8a483d067ca3f，开发分支 abroa/development；独立执行环境为 D 盘隔离 WSL/PostgreSQL17/Redis 和独立 Docker A/B；从未向生产环境提交真实付款，也未更改冻结 P1 历史提交和已应用迁移。

## 1. 可重复执行的真实测试与回归

- **最新独立 Git SHA 全量 Rails：19,280 tests / 117,849 assertions / 0 failures / 0 errors / 9 skips，命令退出 0。** 日志：rails-full-e5fc-20261126T025908Z.log。新 SHA 包括 P4.5 月度 AI 套餐额度与旧 Sure API 重试修复。
- AI 月度额度专项：30 tests / 226 assertions / 0 failures；测试先红后绿，修复用户申报月额度的上限/剩余、月份切换、未知费用保留 null、读权限和非法输入。日志 ai-quota-tdd-20261126T023834Z.log（RED）及 ai-quota-scope-20261126T024045Z.log（GREEN）。
- 旧 Sure API 重试：原测试跳过项恢复并暴露失败，修复 AssistantMessage 错误任务参数和未标记 pending 导致的 422；最新原控制器 7 tests / 23 assertions / 0 failures / 0 skips；日志 sure-message-retry-20261126T025756Z.log。
- 旧阶段独立 P1–P4 业务专项：496 条方法记录（495 PASS + 1 条 Redis 多进程条件 skip），专项 496 runs / 2794 assertions / 0 failures / 0 errors；Redis 多进程另行真实 8-process 测试 1/36 PASS。
- 独立 Docker A 全新建库，真实 HTTP /up、P1–P4 资金/学费/债务/家长授权撤销/A14 Chat Completions 模拟、5 种 Cron、worker restart、实际本地 TCP SMTP/幂等发送、Secret encryption 通过。
- 独立 Docker B 从 P3 合成备份升至 P4 后重启回归，39 张表的旧行逐行内容指纹保留，用户/密钥由明文到加密的合法变更单独验证。
- RsWag 646 规范示例，0 failures，89 pending 文档示例，OpenAPI SHA 保持与 P4 原基线一致；用户新增月度额度在已存在的 provider capabilities 泛化 schema 内，通过真实 API 功能测试验证。
- 本次静态：188 个 Abroa/受影响 Sure 文件 RuboCop 0 violations，Brakeman 0 active warnings / 8 historical ignored，API consistency exit 0，见 static-e5fc-20261126T025955Z.log 和 brakeman-e5fc.json。

## 2. 97 条业务逐项签核

P1 23 / P2 30 / P3 7 / P4 37 = **97 条全部 VERIFIED-SIM+CODE**。每条源代码文件均存在，且可对应具体已执行 PASS 的测试方法；相应测试内容与阶段既有签收、数据库迁移及运行时闭环交叉核对。逐案表 P1_P4_97_CASE_EVIDENCE_REVIEW.md，主矩阵 P1_P4_FULL_ACCEPTANCE_MATRIX.md（状态同步更新）。本次查明并补齐的真实 AI-07 缺口有独立红绿测试，旧 Sure 重试代码缺口也有独立红绿测试，未以修改测试过滤或提高容差掩盖异常。

## 3. 无外部凭证时采用模拟和源码安全审查

- Google OIDC / 注册登录：使用令牌/issuer/sub/verified email 模拟、认证和撤销回归；逐层审查身份绑定、授权及账户隔离。未声明真实 Google 用户授予已测试。
- 银行、海外 provider、Wise、国内账单：文件导入与 provider normalize、幂等、重复回调、跨租户拒绝、退款/匹配/历史 FX、同步失败和并发执行真实 PostgreSQL 测试；第三方 OAuth / API 网络请求使用确定性模拟与防越权源码复核。未声明真实第三方银行账户已连接。
- AI A14：实际 HTTP loopback 兼容模型模拟返回 200/302/401/500/503/错误 JSON/长度边界；源码审查 DNS/IP pinning、SSRF 保护、密钥加密及脱敏、人工确认 token、资源版本/超时及补偿边界；真实银行扣款、任意系统命令、AI 直接改账户余额均禁止。外部商业 AI 凭证未用于本轮验收。
- 邮件：实际本地 TCP SMTP 通信与事务型 outbox/幂等、定时任务及授权再校验通过。外部邮件供应商投递到真实邮箱不在本轮范围。
- 云端支付/上线、真实生产密钥及银行资产变化：按安全规则绝不执行；只检查禁止自动付款和已入账资金映射/状态机的实现代码。

## 4. 安全风险与原 Sure 历史遗留审查

Brakeman 无新活动警告。8 个原 Sure 忽略项全部保留，未清除忽略列表或抑制扫描：
1. Trades account_id：真实控制器测试 93/447 的一部分覆盖账户写权限和租户隔离。
2. RecurringTransactions account_id：源代码限制账户范围/家族归属，同上 93/447 的控制器及业务测试覆盖。
3. SnapTrade provider portal redirect：需管理员身份、用户/家庭自己的 item，目标地址来自服务商 SDK，非 request 任意 URL。
4. SnapTrade OAuth redirect：授权 URL 为 provider 固定地址，使用随机 state、PKCE、常数时间校验 state。
5. FamilyExports ActiveStorage redirect：先做管理员/家庭 export 查找，A13 blob 双附件访问绕过曾修复且有专项测试。
6. Invitations role 输入：管理端身份判断、归属家庭邀请，限制邀请生效与角色。
7. AdminUsers role 参数：super admin before_action、Pundit authorize、最后 super-admin 保护和审计。
8. StyledFormBuilder class_eval：迭代静态 Rails field_helpers，非来自用户输入的可执行文本。

最新总回归有 9 项旧/条件性 skip，**不伪称为实际执行 PASS**。条件性 Redis 多进程和数据库用户名配置测试各已在隔离环境独立执行并通过；原 Sure 已知的 I18n 4 项、AutoSync 2 项、BaseController 占位 1 项仍未强行解禁：I18n 属于排除的语言界面质量范围，AutoSync 的源代码条件（当日首次、开关、账户激活、后台 refresh）已审查且 P1 独立 provider sync/调度实测通过，BaseController 当前资源所有者及授权由大量实际 API 租户隔离测试覆盖。原 Sure 消息 retry 跳过测试已在本次启用修复并实际通过。

全仓 RuboCop 仍有历史 P2 **2 个已应用 migration 的 14 处仅格式性违规**；按不可改写已应用迁移原则原样保留，明确为既有静态格式例外，未影响数据库执行、迁移或业务。前端原 Sure Biome 错误、浏览器 E2E、PWA 以及 P5–P8 未来功能均明确排除，不能由本签收推导为已完成。

## 5. 验收边界及结论

用户批准口径：**可模拟的实际运行，不能安全/现实地用真实服务测试的检查业务及安全源代码，全部通过计通过；排除前端。** 在此限定边界下，P1–P4 核心后端、API、数据模型、历史账本兼容性、安全隔离、独立 Docker/升级和 A14 行为均已验收 **VERIFIED**。本结论不是生产环境真实第三方服务联调签收，也不表示 P5–P8 已完成。原始冻结阶段验收资料、测试日志和早期 NOT VERIFIED 报告作为历史审计证据保留；本文件是最新补验收结果。
