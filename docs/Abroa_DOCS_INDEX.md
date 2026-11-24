# Abroa 开发规格入口
阅读顺序与优先级：根 AGENTS.md（仓库强制规则） -> Abroa_PRD_v1.0.md（产品决策及范围） -> SOURCE_AUDIT -> ARCHITECTURE / DATABASE / BUSINESS_RULES / SECURITY / API -> DEVELOPMENT_PLAN / ACCEPTANCE / DEPLOYMENT -> IMPLEMENTATION_MATRIX。
本套技术文档基于本地 Sure fc576847dcb2b33ad9ef8a9003356978fcaa4ce5 静态初审，新增实体、接口、算法为实施规格，并非已存在代码。P0 必须读实际方法、迁移、路由、测试及运行基线，将命名和兼容细节定稿后再进入 P1。产品范围以 PRD 和最新明确决策为准；任何实现调整不能降低功能、隐私或财务准确性。
后端 P0–P6；新前端 P7；正式验收 P8。公开成本数据库、多人账本、匿名统计后续；价格后续讨论；不做实际资金支付。
开发代理开始时先读 AGENTS 和对应指南，完成 P0，更新追踪表；每任务测试先行、独立提交、真实验收。未经明确授权不自动运行迁移、启动 Rails server、变更凭证；不要修改与项目无关目录。禁止将未执行的测试标为通过或将规划写成完成。
