# Abroa 财务算法与业务状态机 v1.0
依据 PRD §§5–14。下述为确定性领域规则；底层金额符号和现有 transfer 例外以 P0 对 Entry/Transfer/报告代码及测试的验证为准。不得重写现有通用总账。
## 1. 金额及事实
领域边界以非负 magnitude + direction 表达，转入现有 Entry 时通过唯一 adapter 转为原项目符号。禁止混合符号和直接写 balance。所有计算使用 BigDecimal，存储沿用 decimal(19,4)；汇率保留高精度，中间值不逐次显示舍入；按目标币种精度统一舍入，分摊尾差固定按稳定顺序分配，使总额精确守恒。日期以项目时区的本地日归属、UTC 记录时间，闭区间 [start_on,end_on]。报告 as_of、currency、scope 明确。
确认入账且未排除的真实交易形成消费集合；现有 pending、拆分父子、transfer 类别例外须保留原行为。普通内部转账不计日常支出；原项目贷款偿还/投资等专门统计仍按原口径，留学生活消费另外筛选。拆分选择规范化有效子项或未拆分原项，不计两遍。原交易对项目分摊之和<=有效金额，未分摊部分仍在个人总账。退款是实际反向交易，关联原消费，净消费按实际退款日冲减（另提供按原交易追溯的生命周期视图）；不可删除原消费或把退款当普通收入。部分退款总额不能超过原款，超额进入人工确认。
## 2. 导入与去重
parse -> normalized -> identify_account -> match -> post/link/review -> reconcile。稳定来源 ID 及文件行 ID 精确去重；优先复用 entries 原索引。跨源记录独立保存来源证据，多个 source_record 可指向一个真实 entry。
决策顺序：无效/失败/已关闭记录不入账；来源原生退款/转账分流；稳定 ID 命中同源回放；可信已确认银行交易为真实扣款事实；支付渠道在账户、币种、方向、金额、日期窗口、明确订单/参考号及唯一候选一致时可合并元数据。仅日期金额相同或多个候选一律 review，不得自动删除。单纯账户无法确定不创建虚构账户；已确定真实交易但分类未知可入账并单独 review。用户锁定字段不被自动覆盖。支付渠道=元数据，钱包余额真实支付才是钱包账户扣款。
source states: received -> parsed -> linked/posted/review/ignored/error；review -> resolved/dismissed；revert -> reversed 或 conflict。回滚只撤销本次创建或变更且未被后续用户修改的效果；保留跨批次来源，存在后续依赖则冲突提示。自动分类/退款/拨款匹配规则可调整；不得用未经证实的概率阈值宣称准确率。
## 3. FX
转换 target = source * rate(from,to,date)，同币 rate=1。优先已有有效历史汇率，允许经配置的可追溯历史回退并标明日期；缺失 rate 返回 incomplete+missing，不静默为 1，不将未知金额算作零。实际成交率=到账目标币/扣除独立手续费后的源币本金；手续费独立金额/币种/entry，不能重复。示例：扣 9,100 CNY，其中手续费 100，到账 1,000 GBP，成交率 1000/9000 GBP/CNY，9000 是本金；费用 100 CNY；双方本金为同一内部转账。报告使用指定日的 rate snapshot，保存原币、换算值、来源、日期。历史消费使用交易日汇率，当前资产用 as_of 最新可用汇率；更正生成可追踪重算，不改原金额。
## 4. 预算
每节点 scope=(project,period,category filter,currency)，actual=scope 下净个人消费之和；limit_effective=limit+approved_rollover；remaining=limit_effective-actual；committed=尚未支付且属于节点范围的已确认净费用；uncommitted_remaining=remaining-committed。资金预留与 committed 可能对应同一费用，不再扣一次。actual 允许负（净退款）；remaining 允许负（超支）。上级与下级分别查询事实，不累加各节点实际消费。同一 scope 同级重叠须提示并拒绝未明确区分的重复预算；子节点期间必须包含在父节点内、同项目无环。子预算合计超父额度提示而不更改 ledger。滚存仅已关闭周期可用，默认 max(0,remaining)，不自动跨不相容币种/分类，重复执行同一周期只一次。示例：limit 1000、实际 200、待付 300、已预留该 300，则 remaining 800、uncommitted 500，而非 200。
## 5. 资金池
在账户原币维度计算 usable_cash=已确认可动用的非负现金余额（信用额度、投资、应收与预计拨款不计）；reserved_total=现有 Sure goal 及 Abroa 池的唯一真实承诺，重叠表示仅算一次。allocate<=max(0,usable_cash-reserved_total)。每池 allocated 为未消耗分配净额，reserved_for_fees<=allocated，free=allocated-reserved_for_fees；资金池目标≠实际分配。真实支出使账户余额减少且对应池 consume 减少，释放同一费用 reserve；退款按真实入账及原池归属恢复，释放未到账不创造现金。账户因其他消费降至承诺以下时记录 shortfall，不篡改已分配历史；禁止新增超额分配。调池是 release+allocate 的同事务动作，无 entry。多币种池以账户原币约束、报告换算展示；不得仅按总换算值允许超分配。
## 6. 家长、拨款、提议
relationship invited->active->revoked/expired（重新绑定需新同意）。grant active->revoked/expired，版本递增。proposal draft->pending->accepted/rejected/cancelled/expired；accept 同事务检查 actor、scope、目标版本并应用白名单命令；重复确认不执行两次。学生默认有接受/拒绝权；直接编辑需显式 manage grant。
funding plan planned->confirmed->partially_received->received（或 cancelled）；到账量=已确认实际 entry 分配的计划币金额；计划币与原币、汇率快照分开。取消不能删除已经真实到账；保留历史并取消未履行部分。到账不足保持部分；超额未指定部分留未分配，不能无限核销。同一 entry 默认只关联一计划，显式拆分总额<=实际到账。实际到账既可手工录入真实交易再匹配，也可同步匹配，计划本身绝不加余额。家长只读已授权摘要、相关计划确认额。
## 7. 固定费用
net_due=gross-waiver-scholarship_offset+approved_adjustments，>=0；现金到账奖学金不是直接抵扣。各分期金额合计=净应付，跨币付款通过显式汇率快照转换。paid=sum(confirmed payments)-sum(confirmed payment reversals/refunds that reopen obligation)，outstanding=max(0,net_due-paid)，过付需单独记录可退差额。若退款代表减免/取消，先调整净义务再退款；不得把退款一律当义务恢复。状态以金额+日期派生：draft/cancelled 优先；outstanding=0 paid；过截止日 outstanding>0 为 overdue（仍保留 paid 部分）；其余 paid>0 partial，否则 due。押金记录真实资产/应收性质而非默认费用；收回核销资产，扣留部分确认费用。与 recurring occurrence 关联的义务仅预测一次。支付已预留义务同步释放资金池占用。已支付后取消计划不删除真实交易。
## 8. 代付
应收：实际支出 800 GBP，个人消费 200，其他 600 对应可追踪应收资产；利用原有拆分/内部转账到应收账户表达，必须 P0 验证原报表不会将内部转账部分误计为消费。还款 200 是应收资产转入银行的核销，余额应收 400，不计收入。应付：他人替付个人 200 时确认个人费用和应付负债，归还 200 核销负债而非再次消费；现金流只在实际付款发生。状态 open/partial/settled/cancelled，已结算历史不得直接删除。跨币结算保留源金额、核销金额、汇率及真实费用差额；应收应付不是可用现金。禁止多人共享账本进入本阶段。
## 9. 预测
日历按本地日期，horizon 30/90/180。起始现金=选择账户当前可支配现金（不用 pool 叠加）；日现金余额 B[d]=B[d-1]+in[d]-out[d]；未支付固定义务按到期日、部分支付只计未付；历史日常基线默认最近30个完整日净日常消费/覆盖天数，剔除转账、固定费用、代付部分、未确认记录；默认最少14个有可信覆盖的自然日，否则用户预算折算每日或标记 unknown。上述窗口是实施默认值可配置，不假设用户已有历史。负净日常平均下限为0。明确未分类/缺失汇率等不完整输入。保守情景仅纳入已确认未来流入且标记其非现金；可另给不含任何未来拨款的压力情景与包含计划拨款的情景。runway：从 as_of 后首个日预测自由生活资金不足的天数；若无消费且无固定流出耗尽则 null/unbounded，不除零；若超预测区间则 >horizon。shortfall=max(0,-min(B[d]))，first_shortfall 首个 B<0 日期；拨款建议=覆盖缺口加用户配置安全缓冲，时间不晚于首缺口，非承诺。总成本=已发生个人净成本+未来已知净费用+估计日常消费（到项目结束）；无结束日期返回不完整。情景变化只影响模拟，不写 ledger。示例 B0=1000，每天日常20，第10天租金300，无流入：第10天 B=500，第35天 B=0，第36天负，30天余额100、缺口0。
## 10. AI、通知和商业
AI action proposed->confirmed/executing->applied 或 failed，拒绝/过期终止；确认 digest 绑定 actor、目标、payload、版本、expiry，执行时二次鉴权，幂等，undo 通过有权限的逆操作且检查后续版本。原有写工具也要进入此机制，不仅新增工具。
通知 event_key=稳定资源+事件类别+发生版本/时间窗；同收件人只生成一次，投递 queued/sent/failed/retry，撤销权限后发送前重验。用户偏好可关闭非必要提醒。商业权益服务只限制付费增值服务，不限制核心；unknown cost 保持 null，真实收费未授权不发起。
