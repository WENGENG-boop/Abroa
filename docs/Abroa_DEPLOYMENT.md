# Abroa Docker 部署与运维 v1.0
目标为 Docker Compose，复用本地 Dockerfile、compose.example.yml、compose.example.ai.yml、.env.example、docs/hosting/docker.md。现有 example 已有 DB_HOST=db、DB_PORT=5432、REDIS_URL=redis://redis:6379/1、SELF_HOSTED、SECRET_KEY_BASE 必填及 Active Record 加密变量说明。实际服务名称、image、healthcheck 与命令在 P0 完整读配置后定稿，不声称新 compose 已创建。
## 拓扑与配置
反向代理 TLS -> Rails Web；后台 worker -> PostgreSQL/Redis；原始账单及附件 -> 私有 Active Storage 持久化卷/经验证的云存储。DB/Redis 不对公网暴露，Web 仅通过代理或本机端口。共享同一版本 image、密钥及业务配置；定时任务按现有框架，避免多个 scheduler 重复。云端与自托管通过现有 SELF_HOSTED 及明确配置切换，不维护两套核心。
配置清单：SECRET_KEY_BASE、数据库凭证、Redis URL、Active Record 三项加密密钥（全配或按原机制派生）、APP_HOST/外部 URL（实际键 P0 核实）、TLS/RAILS_FORCE_SSL/RAILS_ASSUME_SSL、SMTP、Google OIDC、模型 URL/key/name、金融服务商凭证、政策 URL、时区、存储、feature flags。所有实际 secrets 由部署方注入；不写仓库、镜像或日志。云端未定价格时禁用真实结算；自托管默认核心可用。既有实例密钥必须原样保存，不能随意重新生成导致旧数据不可解密。
## 部署流程（需用户授权环境操作）
1. 锁定 Git SHA/镜像 tag 和依赖，核查 Docker 版本、磁盘、持久卷及端口；生成部署专用 compose/env（保留原示例，不覆盖运行配置）。
2. 新装与升级分别测试；先备份数据库、附件、密钥及部署配置；在隔离环境按原指南运行受控迁移，核查 schema 及账务一致性。
3. 验证 Compose 配置、构建镜像、启动必要服务（实际命令以原 entrypoint 为准），检查 web/worker/db/redis 健康；不得绕过 AGENTS 自动跑迁移或启动 Rails server。
4. 验证登录/邮件/AI/银行/导入/预测任务，真实凭证由部署者提供；无凭证标明未验。
5. 升级失败停止新版本写入，按兼容性恢复上一镜像与经验证备份，不能盲目 downgrade schema；验证数据和密钥后恢复服务。
## 运行维护
健康检查包含 web、DB、Redis、worker 队列积压/失败、provider 同步、AI 请求错误；日志结构化并脱敏，限制访问。备份范围 DB、附件、加密密钥、配置；定期验证恢复到独立实例，明确恢复点/耗时，以实际运维要求确定周期。敏感文件不公开。部署验收记录实际 compose 命令、容器状态、迁移结果、测试与恢复报告。生产规模、RPO/RTO、域名、邮件服务及定价均未指定，P0/上线前确认，不能声称已上线。
