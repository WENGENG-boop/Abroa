# P1–P4 Docker 新建、P3 升级与加密验证记录

本轮源码固定 SHA：38adcae14cff6d04987b7e1e39745c6467899c8d。所有临时资料、Compose、日志、测试数据库和本地 Docker 均在 D:\开发\Abroa 或 D 盘支持的 Abroa-P1-Test WSL 根盘。Windows Docker Desktop CLI 当前不可连接，改用已运行的 WSL 原生 Docker Engine，未操作原有 P1/P2/P3/P4 历史镜像及验收数据库（P3 source 仅 pg_dump/SELECT）。

## A：全新安装、全新数据库

Compose 文件：D:\开发\Abroa\.p1-p4-full-20261126\compose-a.yml；名称 abroa-p1-p4-independent-a；镜像 abroa-p1-p4-full:38adcae14、PostgreSQL 17、Redis 7、Web、Worker。Web 回环绑定 127.0.0.1:3051，数据库/Redis 不向公网开放，隔离内部网络和专用 volume。

依据当前真实 Git HEAD 归档在隔离目录创建 Docker 镜像，依赖镜像来自已存在的 abroa-p3-overlay:119317b9c，仅复制当前代码并重新 bundle check；这是“当前代码运行于本机已有构建依赖基础镜像”，不是公开网络从零重新构建所有依赖。由空库运行 Rails db:prepare，所有适用 Migration 均 up。Docker 4 服务就绪和 /up HTTP 200；A10/A13 合成 GBP 负债与真实收款分离、A13 导出、A14 confirmed proposal、家长 Grant 撤销 200→404 均通过。Cron-smoke 5 类任务入队并执行，在 Worker 重启后再验证 5 类；自动 tick 另在运行的 Sidekiq 上触发成功。加密 backfill dry_run/apply 后重启 Web/Worker，仍 /up 200。

证据：logs\docker-fresh-a-20261126T011059Z.log（DOCKER_A_EXIT=0）；logs\docker-a-encryption-20261126T011529Z.log（DOCKER_A_BACKFILL_EXIT=0）；logs\docker-a-real-cron-20261126T012237Z.log（DOCKER_A_REAL_CRON_EXIT=0）。

## B：P3 → 当前 P4 原样数据升级

源数据库：既有只读 P3 synthetic stage，容器 abroa-p3-stage-db-1，db=abroa_p3_stage。先用 SELECT count 和 pg_dump -Fc 备份到独立 D 路径，并生成 sha256sum；不在源库执行迁移、回填或测试写操作。

| 数据类型 | P3 源 | B 恢复后 | B 迁移 P4 后 |
|---|---:|---:|---:|
| users | 12 | 12 | 12 |
| entries | 10 | 10 | 10 |
| abroa_study_projects | 8 | 8 | 8 |
| abroa_relationships | 6 | 6 | 6 |
| abroa_funding_plans | 4 | 4 | 4 |

B 在全新独立 Docker Compose abroa-p1-p4-independent-b、数据库 abroa_independent_b 及 Web 回环端口 3052 执行 pg_restore、P4 Migration、回填 dry_run 和 apply。Apply **users 12 updated、api_keys 6 updated，failed_count=0**；P3 原始数据保持不变。重新启动 Web/Worker 后第一次请求在容器未就绪时连接 reset，环境修复为等待 HTTP 就绪（不修改业务代码），重试 /up 200、后续数据库、业务实体检查均通过。升级前后数据表行数相同，且 B 有 8 个历史项目及 4 个 P3 拨款计划。进一步 P4 API 合成数据请求在独立 B 进行，不写入源 P3。

证据：logs\docker-p3-upgrade-b-20261126T011356Z.log（首次退出 56：仅重启时序，数据迁移/回填已完成）；logs\docker-b-restart-verification-*.log（B_P3_SOURCE_AND_UPGRADE_ROW_COUNTS_UNCHANGED / DOCKER_B_P3_TO_P4_RESTART_CHECKS_PASS）；logs\docker-b-synthetic-business-smoke-*.log。

## 本轮测试风险及未验证外部事项

Docker A/B 均是合成数据，不能冒充真实外部银行、支付、SMTP、OAuth、模型服务的联调。需依据 PRD 项另审失败迁移回滚、真实 SMTP 接收记录及更完整的数据字段级哈希对照；未验证项目保留 NOT VERIFIED。既有冻结环境、生产账户不在任何更新路径中。所有 Docker Compose 操作均采用新项目名和新数据卷，没有 down -v 或清理旧容器。

复现脚本：D:\开发\Abroa\.p1-p4-full-20261126\scripts 下 run-docker-a.sh、run-docker-a-backfill.sh、run-docker-b.sh、run-docker-b-post.sh、run-real-cron.sh。验收总表路径 docs\P1_P4_FULL_ACCEPTANCE_MATRIX.md。

## 补充：升级后字段级一致性与实际邮件

在只读原 P3 合成环境和隔离升级 B 环境分别计算同一原始主键集合的完整 JSONB 行哈希，对 39 张既有 P1–P3 表逐表比较，全部 MATCH；覆盖 8 个项目、4 个拨款计划、6 个家长关系及原 Sure accounts、entries、families。此核对不只是主键计数，并避免把升级后新增合成数据误认为旧数据。证据：D:\开发\Abroa\.p1-p4-full-20261126\logs\p3-p4-row-fingerprints-20261126T021053Z.log，脚本 scripts/run-p3-row-fingerprints.sh。

环境 A 通过真实本地 TCP/SMTP 服务器接收一封合成通知，并核查重复调用幂等和财务私密字段不外发，未配置任何真实外部 SMTP 账号。证据：logs/smtp-real-local-20261126T020801Z.log。

7cc66fec9 仅对 A14 本地兼容 HTTP 5xx 测试增强，不修改已在 A/B 上部署的生产业务源码，因此此前 A/B 镜像的业务行为仍具对应性；但完整新提交独立代码回归仍以最终 Rails 退出码为准。

## 前端资源真实构建（2026-11-26）

在隔离环境 A 的生产配置 Web 容器内实际执行 `bin/rails assets:precompile`，生成前端 assets/DS 模板产物后通过真实 HTTP /up 健康检查；退出码 0。证据：`D:\开发\Abroa\.p1-p4-full-20261126\logs\fresh-a-frontend-build-20261126T022513Z.log`。此结果为 Rails 资源编译，不是视觉像素对比、浏览器端 E2E 或全仓 Biome 格式验收；后者仍独立列为未完成。
