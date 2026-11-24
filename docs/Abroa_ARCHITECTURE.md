# Abroa 后端架构 v1.0
产品依据：Abroa_PRD_v1.0.md；基线见 SOURCE_AUDIT。设计目标不是替换 Sure。以下命名为拟定实现契约，P0 在实际代码验证后可调整命名，但不能降低功能范围。
## 1. 部署与边界
Rails 8.1.4.1 单体、Ruby 3.4.13、PostgreSQL、Redis/现有 Sidekiq、Active Storage、原有 REST API。Web/PWA 后续，保留既有客户端接口。同步、导入、预测、通知走后台任务；资金写操作使用同步数据库事务。不得新建第二套总账、用户表、银行连接器框架或独立微服务。
## 2. 模块分层
- 现有 app/models：User/Family/Account/Entry/Transaction/Transfer/Budget/Goal/RecurringTransaction 等仍是原有事实来源；新增领域建议 Abroa 命名空间（app/models/abroa），遵循 Rails autoload；公共计算/协调 PORO 置于仓库已有约定位置。
- Abroa::Identity：用户 profile/初始化；现有登录与 OIDC；默认每个独立学生、家长建立自己的 family，保留已有家庭数据；不因绑定家长迁移 family。
- Abroa::Study：项目、学期、账户关联、交易分摊，统一报告查询对象。
- Abroa::Access：关系、grant、policy、proposal、审计；独立跨租户只读投影与有限命令，不切换 Current.user/family 模拟学生。
- Abroa::Connect：SourceAdapter（parse/normalize/validate/capabilities）、SourceRecord、MatchEngine、Review、Posting、Revert；复用 imports/import_rows/statement/provider adapter；统一边界不要求重写每个连接器。
- Abroa::FX：RateResolver、ConversionSnapshot、ExchangeDetails，复用 exchange_rates；成交记录关联真实 transfer。
- Abroa::Planning：项目预算层级和资金池；复用预算查询、Goal 预留；共同 AllocationGuard 控制所有资金承诺。
- Abroa::Fees：费用计划、分期、抵扣与付款关联；复用 recurring occurrence/allocation，不新建重复消费。
- Abroa::Funding：拨款计划、提议、到账核销；与费用/资金池分开，未来计划不创建 entry。
- Abroa::Forecast：只读快照和确定性模拟，依赖 Scope + ledger + planning + FX；定期/事件触发，结果带输入版本、算法版本、as_of。
- Abroa::Receivables：个人代付、分摊、结算；通过现有账务服务录入真实现金及对应应收/应付，不直接更新 Account.balance。
- Abroa::AI：现有 AI router/tools，加动作提议、确认和执行层；统一命令校验；写工具不能绕过命令。
- Abroa::Notify：事件、收件箱、邮件 outbox；复用任务/邮件发送；独立幂等投递。
- Abroa::Commerce：权益、用量、平台管理权限；复用 subscriptions/llm_usages/provider_request_counts，不决定价格。
## 3. 调用与事务
Controller -> authenticate -> Scope/Policy -> command/query -> model/service -> transaction -> after_commit/outbox -> job；薄控制器，不在 ERB 计算。Job 参数只传 IDs，执行时重新验证 scope、授权版本；用户撤销不依赖缓存 TTL。返回 DTO 明确字段白名单，禁止 parent serialize 整个账户/交易对象。
资金/核销/分摊操作锁 account/entry 等稳定顺序，按现有 lock 约定验证；跨多资源检查在同一事务。异常全回滚；外部请求、邮件、模型调用在事务外。写动作记录 request_id、actor、resource、版本和 operation ID；并发冲突返回 409。事件至少一次交付，消费者按事件键去重。
## 4. 事实、衍生与缓存
Entry/Transaction/Transfer 为真实财务事实；规划、拨款、资金池、应收业务关系、预测为独立领域；实际账务仍通过 Sure 录入。支出、余额、净资产、现金流区分。所有计算复用既有排除/pending/拆分口径并增加专属归属维度。缓存键包含租户、actor、scope/grant version、币种、期间和账务版本；撤销、编辑、退款、汇率修正触发失效。禁止共享跨租户缓存对象。
## 5. 兼容与实施
先读取 docs/llm-guides 中 architecture、providers、goals、AI pipeline、testing、API checklist；不覆盖原有 AGENTS。新增迁移保持向后兼容，默认无项目/无家长时行为与 Sure 相同。路由建议 /api/v1/abroa/，既有接口只做必要向后兼容扩展；Minitest 行为、rswag 文档、OpenAPI 同步。上游合并须跑同一验收矩阵。预览 gating 不得变成永久功能缺失。后端 P6 未通过不得开始新 UI。
