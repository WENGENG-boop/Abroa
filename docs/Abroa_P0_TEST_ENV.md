# P0.3 隔离测试环境

仅用于开发与验收。Compose 项目名固定 abroa-p0-test；数据库名称 abroa_p0_test，独立测试用户名、专用卷与 Redis。没有宿主机端口映射，也不启动 Rails 服务或 Sidekiq。禁止挂载含真实 .env 文件的工作区。测试凭证仅为隔离容器内占位值。

在仓库根目录用 PowerShell 显式执行：

`powershell -NoProfile -File bin/abroa-baseline.ps1 -Phase Prepare`：构建镜像、启动测试依赖、安装锁定 gem、初始化一次性测试库。
`powershell -NoProfile -File bin/abroa-baseline.ps1 -Phase Unit`：原版完整 Minitest。
`powershell -NoProfile -File bin/abroa-baseline.ps1 -Phase Lint`：Ruby/ERB/Biome/Brakeman，仅检查、不自动修复。
`powershell -NoProfile -File bin/abroa-baseline.ps1 -Phase System`：隔离 Selenium 系统测试。
`-Phase All`：按上述顺序执行所有检查；Prepare 会重新加载专用测试 schema，不用于任何真实数据。

命令退出状态才是验收依据。停止测试服务可用 `docker compose -p abroa-p0-test -f compose.abroa-test.yml stop`；不自动删除其他容器、卷或数据库。

初次建立状态：Docker Desktop 已通过安装的程序启动，Docker Linux Engine 29.8.0 已确认可连接。后续构建与测试结果须单独记录，不因创建配置而标记 P0.3 完成。
