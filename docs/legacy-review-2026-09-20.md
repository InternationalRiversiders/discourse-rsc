# 旧版行为复查（2026-09-20）

> 2026-09-21 更新：后续实现和当前边界见 [原生适配记录](native-adaptation-2026-09-21.md)。本文保留当时的状态，旧问题复现不能当作当前未修复清单。

本轮是 review，未修改业务实现、未重新部署测试站或生产站。范围包括 RiversideCoin 非棋牌游戏功能及 rsc_reward_to_post。依据为新旧前后端源码、私有快照只读查询及一次性隔离数据库的行为复现。不能用此前“65 个回归测试通过”替代业务规则对照；这些测试没有覆盖下面的旧版约束。

此前修复的热门排序、七种排行榜前 100 名及小数截断不在本轮重新计数。以下是仍未对齐的内容，按影响排序。P1 表示真实资金接管前应修复或明确批准改变规则；P2 表示操作/展示缺失；P3 表示体验或切换配套。

**P1：交易规则与账户状态**

| 编号 | 旧版与当前差异 | 影响、修复方向和依据 |
| --- | --- | --- |
| R01 最短持仓时间 | 旧虚拟币手动平仓要求最近开仓订单至少经过 5 分钟；新 `hold_until` 只在延迟行情成交时设为两分钟，正常虚拟币没有锁定时间。 | 新仓位可提前平仓。应恢复按标的/成交模式区分的持仓规则，同时考虑迁入后未过锁定期的仓位。旧 [assertCryptoPositionCanClose](/opt/RiversideCoin/backend/src/services/exchange.ts:6697)，新 [提交与 hold_until 检查](/opt/discourse-rsc/app/services/discourse_rsc/exchange.rb:26)、[成交持仓更新](/opt/discourse-rsc/app/services/discourse_rsc/exchange.rb:204)。 |
| R02 虚拟币撤单窗口 | 旧虚拟币初始两分钟不可撤单，随后仍待成交或发生订单错误时可撤；股票延迟单是头 10 秒可撤。新版统一成头 10 秒可撤、之后等到过期或供应商错误。 | 两类规则被合并，虚拟币既能过早撤销，也可能在旧版允许时不能撤销。旧 [cancelDelayedCryptoOrder](/opt/RiversideCoin/backend/src/services/exchange.ts:3110)，新 [cancel](/opt/discourse-rsc/app/services/discourse_rsc/exchange.rb:56)。 |
| R03 止盈止损有效性 | 旧版除当前价方向外，还检查止盈超过含双边手续费的保本价，止损必须在爆仓之前触发。新版仅检查当前价方向。 | 例如成本 100、现价 90、爆仓价 85，新版接受止盈 95、止损 70；前者仍然亏损，后者来不及触发。旧 [validateConditionalPrices](/opt/RiversideCoin/backend/src/services/exchange.ts:9643)，新 [protect](/opt/discourse-rsc/app/services/discourse_rsc/exchange.rb:73)。 |
| R04 追加保证金被开仓风控拦截 | 旧追加保证金直接从可用余额转入持仓；计算开仓额度时按名义金额/杠杆计入，不把额外安全保证金当作新增风险。新版 `add_margin` 要求新鲜报价并调用开仓 `Risk.check!`，后者按实际保证金计额度。 | 有余额仍可能无法补保证金；补过保证金的仓位也会挤占后续开仓额度。应分离“降低风险的补保证金”和“增加风险的开仓”。旧 [addPositionMargin](/opt/RiversideCoin/backend/src/services/exchange.ts:2256)、[仓位额度](/opt/RiversideCoin/backend/src/services/exchange.ts:6513)，新 [add_margin](/opt/discourse-rsc/app/services/discourse_rsc/exchange.rb:145)、[Risk.check!](/opt/discourse-rsc/app/services/discourse_rsc/risk.rb:9)。 |
| R05 股票开仓防护漏迁 | 旧版包括：部分杠杆/反向 ETF 仅可平仓、股票开仓名义金额至少 1 RSC、近期成交量参与上限、延迟股票的组合额度。新版没有前三项，`Risk.check!` 对非 crypto 直接返回。 | 旧系统明确拒绝的仓位可在新版建立。应保留 asset_type/close-only 等必要标的属性，逐条移植并补边界用例。旧 [禁止开仓](/opt/RiversideCoin/backend/src/services/exchange.ts:5867)、[金额/流动性限制](/opt/RiversideCoin/backend/src/services/exchange.ts:6431)、[延迟市场额度](/opt/RiversideCoin/backend/src/services/exchange.ts:6513)，新 [submit](/opt/discourse-rsc/app/services/discourse_rsc/exchange.rb:8)、[非虚拟币直接返回](/opt/discourse-rsc/app/services/discourse_rsc/risk.rb:10)。 |
| R06 冻结钱包的持仓语义变了 | 旧风控和条件单扫描仅处理 active 钱包，修改止盈止损也要求钱包可用；新版冻结时会撤挂单，但自动平仓扫描没有钱包状态过滤，protect 也未检查冻结状态。 | 管理员冻结后，持仓仍可能爆仓或触发条件单，用户仍能改条件。需明确沿用旧“冻结持仓”还是采用新规则，并保持前后端一致。旧 [风险扫描](/opt/RiversideCoin/backend/src/services/exchange.ts:2475)、[条件修改](/opt/RiversideCoin/backend/src/services/exchange.ts:2364)，新 [process/protect](/opt/discourse-rsc/app/services/discourse_rsc/exchange.rb:73)。 |

**P2：用户操作与信息缺失**

| 编号 | 当前缺口 | 依据与建议 |
| --- | --- | --- |
| R07 成交模式变成统一排队 | 旧实时股票可以即时成交，只有指定延迟源走行情确认；新所有开仓均 pending，至少等 30 秒，且按分钟任务执行。延迟判断还有旧 `>=120`、新 `>120` 的边界差异。 | 明确哪些是主动改动，再按源和模式实现；不能只显示一条通用下单说明。旧 [placeMarketOrder](/opt/RiversideCoin/backend/src/services/exchange.ts:5364)、[延迟模式判断](/opt/RiversideCoin/backend/src/services/exchange.ts:9331)，新 [delayed/wait](/opt/discourse-rsc/app/services/discourse_rsc/exchange.rb:35)。 |
| R08 下单信息缩水 | 缺费用/保证金预估、可下最大数量、最小量和步进的明确说明、外汇 RSC 名义金额换算；开仓时不能同时提交止盈止损；已有仓位加仓不会自动沿用杠杆。 | 现有杠杆默认 1，给非 1 倍仓位加仓会先报冲突；用户也无法提前判断实际冻结金额。旧 [下单弹窗](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:2900)，新 [trade](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:265)、[下单表单](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:572)。 |
| R09 持仓信息不完整 | 新卡片没显示持仓均价、单仓权益、保本价、风险等级/维持保证金、剩余锁定时间。快捷平仓只提供全平，部分平仓需要手动在通用订单表单选标的、输入数量。 | 旧数据是有这些含义的；尤其缺均价、风险状态会影响交易判断。旧 [持仓卡片](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:2451)，新 [持仓 UI](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:616)。 |
| R10 订单详情没呈现 | 新列表仅时间/标的/方向/数量/状态，未展示成交价、费用、成交金额、预占、盈亏、失败原因、等待/撤单倒计时；平仓、爆仓、止盈止损在表格中都接近普通“已成交”。 | 后端 details 中已有部分数据，但 UI 没接；导入历史还需从归档恢复细分含义。旧 [订单列表](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:2527)，新 [订单列表](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:677)。 |
| R11 图表不会随行情自动更新 | `RscHistory` 构造时加载一次，之后仅点击周期按钮重新加载；同一个标的刷新 props 时，已加载的 candles 优先于新的简略 history。 | 页面写“每 15 秒刷新”，价格可能变而图停住。另缺旧版折线悬停游标和对应价格/时间；周期仍是 1d/1mo 等代码。旧 [定时 chartRefreshTick](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:1044)、[悬停读数](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:3499)，新 [RscHistory](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-history.gjs:22)。 |
| R12 排行详情仍不足 | 缺按用户名直接查询；可按仓位权益排序但表格没有仓位权益列。用户持仓详情缺单仓权益/浮盈亏；订单详情缺日期/盈亏/金额；预测详情没有展示返还金额。 | 排名已对齐不等于详情对齐。旧 [用户名查询](/opt/RiversideCoin/backend/src/routes/exchange.ts:308)、[用户档案](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:3720)，新 [trader DTO](/opt/discourse-rsc/app/services/discourse_rsc/reports.rb:101)、[排行榜 UI](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-ranking.gjs:180)。 |
| R13 钱包流水缺交易对象 | 旧流水包含对方用户名/ID、来源引用、说明、相关帖子/赛事/标的；新版接口丢掉这些字段，仅返回类型、金额、余额和时间。原生与历史流水被拆成两个列表，缺旧奖励/其他活动分类。 | “谁给谁转账、为什么扣钱”仍不能从流水完整追溯；通知不是完整历史的替代。旧 [toUserLedgerEntry](/opt/RiversideCoin/backend/src/services/points.ts:1033)，新 [entries](/opt/discourse-rsc/app/controllers/discourse_rsc/wallet_controller.rb:19)、[legacy_entries](/opt/discourse-rsc/app/controllers/discourse_rsc/features_controller.rb:35)。 |
| R14 赛事排序与展示不对齐 | 旧赛事支持足球/篮球、开放/热门/截止/未开放筛选，优先直播/待开赛，保留超过七天仍未结算的本人比赛。新仅联赛筛选，按开赛时间升序截 100 条；比分已返回但没显示，参与人数、预计返还、赔率更新时间/不可预测原因也缺。 | 赛事多时旧已结束比赛会挤掉即将开赛场次；延期老比赛会消失。当前快照“七天前仍 pending 的比赛”为 0，后一个属于已确认代码分支遗漏，未声称已有用户受影响。旧 [listWorldCupMatches](/opt/RiversideCoin/backend/src/services/worldCup.ts:276)、[筛选 UI](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:2593)，新 [state](/opt/discourse-rsc/app/controllers/discourse_rsc/dashboard_controller.rb:29)、[赛事 UI](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:710)。 |
| R15 赛事卡片会遗忘旧预测 | 新版把“我的最新 100 条预测”与赛事列表在浏览器拼接；更早但尚有效的预测可能不在其中，页面会变成“提交预测”，后端再报重复，而无法在该卡片修改。旧版每场比赛直接关联本人的预测，不受历史列表截断影响。 | 快照中 4 个账号超过 100 条预测，证明截断真实存在；是否恰有仍可修改场次落在 100 条外需针对运行时验证。应按当前赛事查本人预测，历史单独分页。旧 [LEFT JOIN 本人预测](/opt/RiversideCoin/backend/src/services/worldCup.ts:297)，新 [limit(100)](/opt/discourse-rsc/app/controllers/discourse_rsc/dashboard_controller.rb:30)、[find prediction](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:164)。 |
| R16 红包页面与历史缺字段 | 缺“我领过的红包”入口、剩余总金额、本人本次领取金额的突出显示、随机范围、复制分享链接按钮；自己的红包仅最近 30 个。领取通知跳钱包首页，不能直接定位红包。 | token 保留不等于交互完成。旧 [MyRedPacketsResult](/opt/RiversideCoin/backend/src/services/redPackets.ts:68)、[领取页](/opt/RiversideCoin/web/components/exchange/RedPacketClaimPage.tsx:174)，新 [packet_json](/opt/discourse-rsc/app/controllers/discourse_rsc/dashboard_controller.rb:95)、[notification rsc_path](/opt/discourse-rsc/app/services/discourse_rsc/notification_delivery.rb:19)。 |
| R17 红包豁免范围变窄 | 旧有效限额豁免者可绕过每日限制及红包总额 300/单份 100 上限；新仅管理员绕过红包上限，Exemption 只影响每日出账限制。 | 同一获批用户迁移后仍可能被拒绝发红包。旧 [exemptDailyLimits](/opt/RiversideCoin/backend/src/routes/wallet.ts:306)，新 [RedPackets.create](/opt/discourse-rsc/app/services/discourse_rsc/red_packets.rb:16)。 |
| R18 金额格式仍有遗漏 | 持仓总保证金、单仓爆仓价仍直接输出金额字符串；K 线 title 仍是原始 OHLC；通知金额使用原值。 | 上轮处理了排行和多数列表，但不能声称全站统一。旧精度规则与用户新增“截断”要求应形成按金额/价格/数量分开的清单。新 [总保证金](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:512)、[爆仓价](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:645)、[图表 title](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-history.gjs:143)。 |
| R19 管理目录只展示前 500 个 | 新后台按 symbol 取 500 条，未提供标的查询/分页；钱包检索也只匹配用户名，不能按用户 ID 查询。资金/审计也仅最近 50 条。 | 快照总目录有 2,508 个，意味着 2,008 个不在后台列表；虽然可手填部分操作，仍明显弱于旧后台。旧 [后台查询](/opt/RiversideCoin/web/components/admin/AdminPanel.tsx:498)，新 [admin_state](/opt/discourse-rsc/app/controllers/discourse_rsc/features_controller.rb:46)。 |

**P3：体验和切换配套**

| 编号 | 差异 | 处理建议和依据 |
| --- | --- | --- |
| R20 默认分类 | 旧股市默认“可交易”，新默认“全部”；热门是排序，和分类是两件事。 | 生产可恢复旧默认或明确选择；只读快照的历史报价都不能交易，不能直接改为“可交易”导致空列表。旧 [category 初值](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:536)，新 [category 初值](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-market-list.gjs:13)。 |
| R21 打赏展示简化 | 旧主题可点用户名打开论坛用户卡、悬停看时间，超过 10 人限制列表高度；新纯文本用户名、默认折叠、无时间显示。 | 汇总金额能用，但论坛内体验未等价。旧 [reward-post-info](/opt/rsc_reward_to_post/javascripts/discourse/components/reward-post-info.gjs:28)，新 [rsc-post-tips](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-post-tips.gjs:37)。 |
| R22 账户概览与冻结说明 | 旧概览有名义敞口、可交易市场数，钱包显示待成交预占和冻结原因；新版主要只有可用余额、保证金、仓位权益、浮盈亏和持仓数，缺预占说明和冻结原因。 | 托管本身是正确的，但用户看到余额减少时难以知道预留在哪。应补账户字段与明细入口。旧 [账户接口](/opt/RiversideCoin/backend/src/routes/exchange.ts:179)、[概览](/opt/RiversideCoin/web/components/exchange/ExchangeApp.tsx:1755)，新 [state](/opt/discourse-rsc/app/controllers/discourse_rsc/dashboard_controller.rb:33)、[概览 UI](/opt/discourse-rsc/assets/javascripts/discourse/components/rsc-dashboard.gjs:510)。 |
| R23 归档不等于可继续办理 | 旧 market_add_requests 等历史表被归档，但没转成原生待审批记录；将来生效的限额豁免也未导入可执行规则。 | 当前快照申请表为 0，不构成本次数据丢失；正式停写快照若出现记录必须处理。旧请求须保留状态、申请人和审核历史；未来豁免需支持 starts_at。新 [LegacyImport](/opt/discourse-rsc/app/services/discourse_rsc/legacy_import.rb:86)、[仅导入当前生效豁免](/opt/discourse-rsc/app/services/discourse_rsc/legacy_import.rb:148)。 |
| R24 旧链接和持续运行仍待切换验收 | 红包 token 保留，但旧站链接如何跳到新插件、旧打赏主题如何下线防重，需要实际切换配置。实时行情/分钟任务容量、切换后持续业绩曲线仍是已有待办。 | 本轮未改生产入口，也未把其误报为已迁移完成。链接兼容需在确定接管入口后验收；旧 WebSocket→REST 是已记录的架构变化，应测体验和容量，不要求逐行搬回旧架构。见 [私有测试说明](private-testing.md)。 |

核对中同时确认：会员认证改用 Discourse、旧待成交单明确取消且不二次退款、历史账本不重放、快照报价不能交易，均是已有约定，不列为漏迁。预测改选时按最新赔率重新锁定，旧版也是如此，未当作缺陷。今日奖励基本计分和卡片内容也已对应（登录 + 发帖回复，最多 10），未把旧 API 多几个计数字段夸大为计分遗漏；奖励历史分类不足已包含在 R13。

建议先完成 R01–R06 的规则修复和新旧对照回归，再补 R08–R18 的用户操作与信息，最后处理后台检索和切换配套。代码层面仍有明确的真实资金接管阻塞项；私有只读预览可以继续用于检查界面。

**隔离行为复现结果**

使用临时容器、独立 PostgreSQL/Redis、`--network none`，只挂载只读源码；没有复制生产卷，没有使用私有常驻演示库。每个场景在独立事务里创建合成资金后回滚，容器已销毁。

| 场景 | 原生插件实测结果 | 对照旧版 |
| --- | --- | --- |
| 虚拟币提交后立即撤单 | `canceled` | 无报价错误时，前两分钟应拒绝 |
| 开仓订单创建两分钟后成交并立即手动平仓 | `filled`，`hold_until=null`，仓位已删除 | 还未满足五分钟，应拒绝 |
| 均价 100、现价 90，止盈 95 / 止损 70 | 两者同时被接受；显示爆仓价为 85 | 止盈低于保本线、止损晚于爆仓，均应拒绝 |
| 余额约 79.94，5 倍仓位追加 40 保证金 | `position_risk_limit` | 旧追加保证金不走开仓额度检查，余额足够可补 |
| 冻结钱包后修改止盈、行情跌至爆仓 | 修改被接受，仓位被强平 | 旧冻结账户不可修改，且不参与风险扫描 |
| 股票 100 RSC/单位，提交 0.001 单位 | 0.1 RSC 名义金额订单进入 `pending` | 低于股票 1 RSC 开仓门槛，应拒绝 |

复现脚本及原始输出：`/opt/rsc-private-preview/parity/review_probe.rb`、`review-probe-results.log`。以上是问题复现结果，不是修复后的验收；本轮没有把预期错误行为写成正式通过的回归测试。
