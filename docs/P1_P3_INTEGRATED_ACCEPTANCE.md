# Abroa P1–P3 联合验收报告（2026-11-25）

**状态：VERIFIED — P1、P2、P3 后端联合验收通过。** 已执行完整 Rails 回归、跨阶段真实 PostgreSQL/HTTP 账本链路、历史 Schema 升级及回滚、全 API 文档与安全检查、固定 SHA 独立 Docker 预生产复验。此结论不等同于正式生产上线或 P4–P8 验收。

## 版本边界与测试隔离

- 工作目录：`D:\开发\Abroa\Abroa`，分支 `abroa/development`。
- 已核对当前分支通过 Git 祖先关系包含 P1 冻结提交 `66b68eac4`、P2 冻结提交 `2f9152daa`、P3 业务提交 `119317b9c`。
- 联合验收原始 HEAD：`692f9ad7f43eb6672a27374b13c87acdf2a5d0ed`；本次修复提交：`66656779d`（旧代码安全格式修正及 SSO 文档夹具）、`fa9c62c3d`（修正 P3 迁移的原始 CHECK 约束可逆性）。后两者不改变已验收资金或权限业务判断。
- D 盘支撑的 WSL 发行版 `Abroa-P1-Test`；独立 PostgreSQL 17 测试集群 `abroap3`、数据库 `abroa_p3_joint_full`、`abroa_p3_joint_updated`、`abroa_p3_joint_docs`；Docker P3 专设 `abroa_p3_joint_upgrade` 测试 P1→P3 升级；没有在真实生产数据库执行迁移/测试、没有实际银行连接。
- P2 Docker Compose 项目 `abroa-p2-stage`（127.0.0.1:3042）、P3 `abroa-p3-stage`（127.0.0.1:3043）分离；两套数据库、Redis、存储卷互不复用。仅 P3 stage 使用合成测试用户及交易。

## 实际验收证据（不得汇总重复执行次数）

| 检查门槛 | 本轮实际结果 | 日志 |
| --- | --- | --- |
| P1/P2/P3 Git 冻结祖先 | P1、P2 均为当前 HEAD 的祖先，Git 退出码 0 | Git `merge-base --is-ancestor` |
| P1–P3 Rails **全量回归（全新 PostgreSQL DB）** | **PASS：19,171 runs、117,058 assertions、0 failures、0 errors、10 skips，退出码 0**；测试运行快照为 `692f9ad7f`，所有项目代码由 Git archive 恢复；后续 `66656779d` 只修复空格/文档夹具，`fa9c62c3d` 只修复数据库迁移逆向约束。修复提交均另经专项回归、真实迁移和最新镜像复测。 | `D:\开发\Abroa\.p3-env\logs\20261125T050424Z-209577.log` |
| P1→P2→P3 **实际 Docker 跨阶段链路** | **PASS**：P1 bank provider 导入幂等、来源去重；P2 单笔 100 GBP 真实 Entry 分配 60/30、余 10、账本余额不变；P3 家长只见有权限项目、授权 API 200→404、私密 Entry/Account ID 无泄漏。退出码 0。 | `D:\开发\Abroa\.p3-env\logs\p1-p3-joint-stage-*.log`；脚本 `.p3-stage/p1-p3-joint-smoke.rb` |
| P2/P3 已运行服务健康 | 两个 Windows localhost `/up` HTTP 均 200，P2 不修改 | 实际 `curl.exe` |
| P1–P3 文档/原版 API rswag | **PASS**：618 examples，0 failures，89 documentation-only pending；按修复后的服务端 Google issuer/subject/email_verified 测试样本重新执行，未放宽验证逻辑 | `D:\开发\Abroa\.p3-env\logs\20261125T051132Z-218517.log`、`20261125T051314Z-220900.log` |
| OpenAPI 重新生成与路径一致性 | **PASS**：618 examples，0 failures，89 文档用 pending；独立生成文件和 `docs/api/openapi.yaml` 逐字节一致；API endpoint consistency 退出码 0 | `20261125T051402Z-221891.log`、`20261125T051412Z-222167.log` |
| P1/P2/P3 RuboCop | **PASS**：扩展至 155 个相关 Ruby 文件，修复 20 个 P1/P2 历史文件中的 222 个格式提示后，重跑 0 offenses、退出码 0；格式修正不改变业务语义 | `p1-p3-joint-rubocop.log`、`p1-p3-joint-rubocop-fix.log` |
| 全应用 Brakeman | **PASS**：234 控制器、871 模型、0 错误、0 未忽略安全告警；仍有 8 项上游历史忽略项和 1 个过期忽略标识 | `p1-p3-joint-brakeman.txt`、`p1-p3-joint-brakeman-run.log` |
| P1→P3 最新业务修复 SHA 的 P3 Docker 完整复验 | **PASS**：固定镜像 `abroa-p3-overlay:fa9c62c3d`，P3 六项迁移均 `up`，P3 资金流水 400-100=300 GBP、撤销授权 API 200→404、两项 Sidekiq 任务在 Worker 重启前后均实际消费；`P3_STAGE_ALL_CHECKS_PASSED`、退出码 0。基于已验收 P2 镜像 + 最新完整 Git archive，非依赖全新下载构建。 | `D:\开发\Abroa\.p3-stage\logs\docker-p3-acceptance.log` |
| P1 冻结 Schema→P3 **真实迁移、数据保留、P3 回滚/重升级** | **PASS**：在独立 `abroa_p3_joint_upgrade` DB 中，从冻结 P1 SHA `66b68eac4` 的 `db/schema.rb` 建表，插入合成学生家庭、账户、75 GBP Entry；向前执行至 P3 六项迁移，历史用户/账户/Entry 均未丢失；实际依次回滚 `20261125105000`/`104000`/`103000`，核实原有提议 CHECK 约束恢复，再向前升级，历史交易保持 75 GBP，退出 0。 | `D:\开发\Abroa\.p3-env\logs\p1-p3-real-upgrade-20261125T052514Z.log` |

## 跨阶段实际账本与权限观察

本轮新增在同一个 Docker Web 容器、同一个真实 PostgreSQL 中执行的贯穿检查，与孤立的模型 mock 不同：
1. P1：`Account::ProviderImportAdapter#import_transaction` 为独立学生家庭生成一条 100 GBP 已确认消费；同外部单号重复采集仍是同一个 Sure `Entry`；`Abroa::ProviderSource.capture_existing!` 两次返回同一个来源证据，不生成第二条交易。
2. P2：两个分别归属于该学生的 StudyProject，对这条 Entry 分配 60 和 30 GBP，剩余 10 GBP，`ProjectSummary` 分别输出 60.0/30.0 GBP，无缺汇率，分摊动作前后 `Entry.count` 和真实账户 `balance` 均不增加或改变。
3. P3：家长独立 `family_id`，关联不自动带 Grant；学生仅向项目 A 授予 `summary`。家长可见 A 的 60 GBP，不可见项目 B，也不泄露银行账户或交易 ID；HTTP 请求在 `Grant.revoke_for!` 前返回 200，撤销后返回 404。

历史阶段验收（仅作追溯，**不计入本轮新跑数量**）：P1 `docs/Abroa_P1_ACCEPTANCE.md`、P2 `docs/P2_BACKEND_ACCEPTANCE.md` 与 `D:\开发\Abroa\.staging\P2_STAGING_ACCEPTANCE.md`、P3 `docs/P3_BACKEND_ACCEPTANCE.md`。

## 修复记录与不可过度解读的范围

- 初次扩大 RuboCop 覆盖时有 222 个仅涉及 array/hash 字面量空格的格式提示，来自 20 个既有文件；经 `rubocop -a` 安全修正并重新检查为 0。修复提交 `66656779d`。
- 初次全量 rswag 遇到 4 个旧 SSO 文档示例因缺少 Google 可信声明返回正确的 401。更正 `spec/requests/api/v1/auth_spec.rb` 中缓存状态为有效 `issuer`、`subject`、`email_verified=true`；原 `Abroa::GoogleIdentity.valid_pending?` 校验**未变**。随后全量 rswag 0 失败。
- 首次额外用最新版 Schema 逆向迁移到 P1 的检查暴露了 P3 `20261125103000` 变更中缺失旧约束表达式的问题（测试日志 `p1-p3-joint-upgrade-20261125T052109Z.log`，退出 1）。在 `fa9c62c3d` 补全旧 CHECK 表达式后，改用**真正的 P1 冻结 Schema** 重建独立测试库，实际 P1→P3 全量升级、历史数据保留、P3 三项回滚/重升级均退出 0（`p1-p3-real-upgrade-20261125T052514Z.log`）。从未执行 P2 或真实生产数据回滚。
- 修复提交 `66656779d` 在新增独立数据库中跑完 P1–P3 模型及 API 控制器专项回归：**260 个测试、1,620 次断言、0 失败、0 错误、0 skip，退出码 0**，日志 `D:\开发\Abroa\.p3-env\logs\20261125T051750Z-227665.log`。随后 `fa9c62c3d` 仅改变迁移逆向约束记录，已在最新固定镜像和真实旧版 Schema 升级/回滚/重升级中实际验证。全量 Rails 有 **10 个 skip**，rswag 的 89 个 `pending` 为文档专用描述，不等于执行验证。Brakeman 的 8 个忽略项不得称为 0 个总风险。
- 没有真实 Google OAuth/OIDC 凭据、国内银行真实账单、生产资金、生产部署、线上通知投递或正式运营负载验证。按现行阶段验收口径，模拟数据与无法外部联调项的针对性代码审查可以满足 P1–P3 **后端阶段**验收，但不能替代上线验收。
- P0 的全部环境基线签收、P4–P8、完整 P6 A17 性能/备份恢复、P7 UI/PWA 和公开发布均不包含在 P1–P3 本次结论中。

**最终联合验收结论：VERIFIED（限 P1–P3 后端及 D 盘独立预生产）。** 本轮实际全量 Rails 测试退出码 0、最新业务修复提交专项测试退出码 0、最新 Docker 固定 SHA 真实资金链路/Worker 退出码 0、P1 冻结 Schema→P3 数据保留和迁移回滚退出码 0；文档和安全检查通过。Git 实施修复记录为 `66656779d` 与 `fa9c62c3d`，本联合报告签收为后续独立文档提交。不得推断真实生产已部署、银行/OIDC 已外部联调，或 P4–P8 已验收。
