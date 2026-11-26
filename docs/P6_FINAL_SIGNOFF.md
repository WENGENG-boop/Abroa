# Abroa P6 — 全后端联合验收、性能、安全与正式签收记录

**状态：VERIFIED — P6 全后端验收通过；P7 前端遗留格式及 P8 真实第三方联调不在此签收范围。**
签收基线：`abroa/development`，P5 `a339eff9343c8da94ae88ed6b9c4f23eda60bc59`；P6.1 已独立提交 `421c68e13ed9f547045d166318d27a594e2e4063`。全部开发/数据/日志/容器均为 D: 承载的隔离 WSL/Docker，没有修改 C: 用户数据、生产服务器、真实资金、P1–P5 的已验收数据库或容器，也没有推送 GitHub/合并分支/开始 P7 或 P8。证据根目录 `D:\开发\Abroa\.p6-env\logs\`，可从每个证据文件重放执行命令与结果。

## 1. 独立完整 Rails/Minitest 基准

`run_full_final.sh` 在专用 PostgreSQL 17 / Redis 7 中执行 `bundle exec rails test`，设置 `SELF_HOSTED=false`、单工作进程，**19332 runs / 118269 assertions / 0 failures / 0 errors / 9 skips，退出码0，1642.019463s**。日志 `p6-full-final.log` / `p6-full-final-wrapper.log`。相对 P5 历史基线 `19328/118189/0/0/9`：实际新增4个测试、80个断言；P6 增补的全新用户注册/登录/引导、跨模块财务闭环、原币 FX 与查询数回归均计入最终完整运行。

早期两工作进程下原 Sure `FamilyMerchant` PostgreSQL 唯一索引时间同步用例曾发生1次仅限“预期锁等待未被检测”的失败，原用例单独 1/4 通过；未放宽原 10s 等待、删除测试或改变期望值，同一套件单工作进程最终 0 失败。D: 日志保留失败和成功的独立证据。

历史9次 skip 未伪称通过：I18n 检查4（文件规范化、缺少/未用翻译 key、插值一致性），`AutoSyncTest`2（上游功能标记暂时禁用），`RecurringTransaction::PipelineTest`1（DATABASE_URL 环境优先于 database.yml），Sure BaseController1（作者注记由控制器实例覆盖），`UsageRedisTest`1（要求单独的真实 Redis 设置）。对对应文件 `--verbose` 检查 **220/1305/0/0/9、退出0**，`p6-skipped-test-audit.log`。其中 Redis 条件测试又被**真的启用并独立执行**：八进程原子竞争，**1 run/36 assertions/0失败/0错误/0跳过，退出0**（`p6-redis-atomic-claims.log`）。

## 2. A00–A17 后端真实验收

A00 先核对 Git SHA、状态和 P0 独立未提交修改；A01 全新注册/邮箱登录/OAuth Token 与 onboarding/学生项目实际 HTTP；A02 USD/GBP/CNY/JPY/三位小数 FX 和原币账本；A03 正规化交易导入/银行同源去重/原 Sure 唯一索引；A04 双项目拆账+不得过量；A05 多周期预算；A06 资金池、Goal 与账户预留；A07 学费120 GBP/50 GBP幂等分期核销/70 GBP未付；A08 家长摘要及异家庭/撤权404；A09 汇款；A10 个人代付/债务；A11 现金流预测；A12 站内通知/SMTP不确定送达重试逻辑；A13 报表/FX/导出权限重检；A14 AI 建议、拒绝、确认、旧工具隔离；A15 平台权限/审计不可改/模拟订阅配额；A16 自托管与云端安装升级恢复；A17-1 跨模块 API 黄金流程；A17-2 固定规模真实 PostgreSQL 性能。详见 `P6_BACKEND_ACCEPTANCE.md` 逐项实现/测试/证据对应和 `P6_INTEGRATION_TESTS.md`。

实际 P6 专项包括核心12/91、家长13/89、财务真 PG 竞争8/31、AI37/216、平台32/223、黄金API1/40、新用户1/29、外币API1/4、优化后18/155，全部0失败、0错误；互有测试交集不对其累加冒充完整运行。

## 3. 金额、性能及隔离完整性

P6 唯一发现的业务性能缺陷为 `ProjectSummary` 逐条查账：35条真实 GBP 分配原需 **144 SQL**，先写失败回归，优化后 **8 SQL**，精确 GBP350保持不变，原 Sure Entry/Balance 不写改；1/7 查询计数回归和18/155财务关联回归通过。

固定随机种子20261126、16个合成家庭、20000条交易及账本、1250笔项目分配、12期预算、500导入、1200通知：项目汇总 **8 SQL、312.88ms，GBP27698准确**；100条账本分页2.72ms、导入28.78ms、通知9.19ms；跨租户非法可见账户0，进程RSS365948kB；PG EXPLAIN 实际采用项目索引，单次 SQL 执行0.254ms。扩展测试：500同源 ID 正确匹配15.842ms；预算总额GBP30000准确；后台16家庭20000条汇总12.117ms；实际预测重算21 SQL/586.714ms，完整无永久缓存；PostgreSQL直接重复INSERT被唯一索引拒绝，20000条原账金额汇总GBP927928不变。证据 `p6-scale-benchmark.json`、`p6-extended-performance.json`，详见 `P6_CONCURRENCY_PERFORMANCE.md`。未根据这些单次数字虚构先验SLO。

## 4. 安全、部署与故障恢复

Brakeman 全量报告0未忽略警告、0错误、8条继承忽略项和1条废弃忽略；独立审查了旧 Sure OAuth跳转、旧API权限、导出路径、批量赋权、import CSV、AI 模型 SSRF/IP固定、明文密钥、平台角色。无已证实未修复的严重越权、财务余额破坏、审计篡改。审计日志 PostgreSQL **直接 UPDATE / DELETE 均失败，记录原样保留**。参见 `P6_SECURITY_AUDIT.md`，历史忽略警告不是“零历史风险”。

旧Sure及P4两份历史合成数据库分别实际迁移到P6，重复迁移、从零安装、pg_dump/pg_restore、金额总和/原始字段 SHA 比较、错误数据库凭证拒绝，**均退出0**；保留历史账户余额总和1099750.0000、Entries7145.0000，schema版本20261126130100。自托管 Web/Worker HTTP200、密钥重启、真实 Sidekiq队列恢复；PG/Redis中断/恢复且账本原始指纹不变。云端 `SELF_HOSTED=false` Web/Worker 两容器健康，内部 /up=200、未授权accounts=401；实际 Sidekiq失败自动重试**2次成功**，合成测试 job 已从隔离副本清理。详见 `P6_DEPLOYMENT_RECOVERY.md` 和相应 D: JSONL及日志。全程没有生产容器或真实收费。

## 5. 静态及接口一致性

- 全库 `bundle exec rubocop`：**3884文件/0offenses/退出0**（旧迁移数组排版14项已只修格式），`p6-rubocop-full-final.log`。
- `bundle exec erb_lint --lint-all`：**857文件/0错误/退出0**，`p6-quality-erb_lint.log`。
- D盘 Biome v1.9.4 **JS lint 158文件/0错误/退出0**，`p6-biome-lint.log`。额外的 `biome check .` **163条继承前端/biome.json 格式差异，退出非0**，`p6-biome-check.log`；这些格式问题属P7前端遗留，不能擅自修改前端，也不能假称全仓Biome格式检查成功。
- API endpoint consistency + compliance 退出0，旧 FinanceKit 真正支持 API Key/OAuth，两种都保留，扫描器字面 `OAuth` 为启发式提示；rswag **676 docs-only examples/0failed/89pending**，退出0，pending不是执行功能成功。
- Browser System Tests：Rails最小测试镜像无 ChromeDriver，原尝试有 `NoSuchDriverError`；已在 P6 D盘 Docker 下载独立 Selenium Chromium 并通过**真实一条系统用例1/1/0/0/0**，完整 System suite 另运行中，正式签收前必须记录其结果，不能以Smoke代替所有System Tests。System UI/PWA前端修复不属于P6开发边界。

## 6. 真实第三方接口未验证事项

**Google 的真实认证重定向及回调、Plaid/TrueLayer/支付宝/微信/外部FX真实服务器、远程LLM模型与密钥、SMTP真实收件、收费供应商Webhook和退款、生产环境部署**都没有真实联调；项目已对源码调用链、权限核对、财务原始约束、入站数据校验和幂等路径做专项审查并通过确定性fixture/本地模拟。**模拟/代码审查通过 ≠ 外部服务已验证。** 在后续生产集成阶段须使用测试商户或沙盒重验，禁止真实付款/生产交易测试。

## 7. Git 签收与保留事项

P6.1 独立提交 `421c68e13ed9f547045d166318d27a594e2e4063`；P6.2 已独立本地提交 `e559aeb9abbba37afff26a40753a22466c659228`，相应源码、测试和证据已冻结；最终 P6 只在满足签收门槛时本地提交。需要的准确提交标题依次 `P6.1: verify integrated backend business flows`、`P6.2: audit security concurrency performance and recovery`、`P6: complete integrated backend acceptance`。本项目现有 P0 的独立 `docs/Abroa_IMPLEMENTATION_MATRIX.md` 修改和三个未跟踪文件必须保留，不得借 P6 提交误纳入。严禁 Git push、merge、生产部署。

## 8. 最终真实浏览器 System Tests（后端门槛完成）

单独 Selenium Chromium 156.0 / Selenium Grid 4.54.0，以 D 盘 P6 Docker 网络和隔离 PostgreSQL/Redis 真实运行，原 Sure 浏览器级 `bundle exec rails test:system`：**511 runs / 2817 assertions / 0 failures / 0 errors / 0 skips，退出码 0**。执行脚本 `D:\开发\Abroa\.p6-env\run_system_remote.sh`，证据 `logs/p6-system-remote.log` 与 `logs/p6-system-remote-wrapper.log`。先使用真实 Selenium 测试独立进行英镑交易显示 smoke：1 test/1 assertion/0失败，退出0，再全量执行。最初的本地 ChromeDriver 缺失和 Selenium 健康检查 JSON 空格错误均在**仅 P6 测试基础设施**修复，未修改产品 UI 或原始系统测试断言。

P6 独立证据 gate `verify_final_gate.py`：所有受检后端及浏览器项目 **PASS**；日志 `logs/p6-final-evidence-gate.json`。本签收仅为本地模拟/源码审查+实际隔离数据库与浏览器验收，不代表 P8 正式生产上线，也不掩盖额外 `biome check` 的前端格式差异和历史测试跳过。
