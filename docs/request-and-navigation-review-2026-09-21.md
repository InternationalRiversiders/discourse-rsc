# 行情保护、入口与旧版细节复核

2026-09-21。承接 `final-review-2026-09-21.md`。上一轮“可以安排正式接管”的判断过早：对真实来源的连通性验证不等于请求限流策略完整。本轮纠正这一点，不以已有业务测试通过来代替逐项源码核对。

## 修补内容

1. **行情请求保护**：Yahoo 全站共享 1 秒请求间隔，其他来源共享 250 毫秒间隔；网页、交易、搜索、图表及 Sidekiq 使用同一个 Redis 限流器，A/B 同库实例共享状态。等待队列最长 3 秒，满时返回繁忙，不无限占用论坛线程。429 按 `Retry-After`（秒或 HTTP 日期）冷却，缺失/无效时 15 分钟；403 冷却 15 分钟，网络错误和 5xx 冷却 2 分钟。后到的短冷却不会覆盖长冷却，排队后再次检查冷却。Redis 不可用不会放行 HTTP。
2. **按需缓存**：查看普通行情 120 秒、延迟行情 90 秒、下单和修改止盈止损 20 秒；同一标的的页面与后台共用互斥和缓存。失败保留真实的旧时间戳，不会将过期价格变成可成交价格。单标的失败默认 120 秒内不再尝试，队列繁忙时 15 秒。成交仍要求收到报价不超过 120 秒、来源时间满足延迟及实际开市条件。
3. **后台请求量**：持仓/挂单优先，开市且报价超过 60 秒才刷新；冷门目录每轮最多 5 个，每个缓存 15 分钟。单轮仍有 45 秒时间预算，过载轮转并报告容量问题，不以提高供应商请求速度解决。后台容量判断不再仅比较持仓数和批量大小，还考虑 Yahoo 请求时间预算；该估算不承诺网络故障下仍有足够容量。
4. **交易所时段**：恢复旧目录的当地时间、午休、周末、夏令时，以及外汇纽约周日 17 点开市/周五 17 点收市。数据源可以额外关闭节假日行情，但不能打开本地休市时段。应用于查看刷新、后台调度、交易校验与前端可交易状态。未知时段继续向数据源查询，不永久判成休市。
5. **图表**：同一标的/周期合并并发请求；日内缓存恢复 2 分钟，休市复用缓存。来源失败时保留旧图表，明确显示缓存提示，更新时间不改变。已有旧快照保持归档标记，不可交易。
6. **导航**：钱包、股市、赛事、排行榜、管理共用顶部标签，排行和管理不再只有返回链接。手机标签可换行；普通会员不显示管理入口，仅有管理权限的账号仍不显示需要会员权限的标签。
7. **管理与审计**：补回后台市场分类筛选（筛选后分页）；旧 `exchange_order_rejections` 对应新的 `order_rejected` 审计，记录失败原因和有限长度的请求字段。失败审计不创建委托、成交或资金流水，不吞掉原始错误。

## 对照范围和边界

重新枚举旧版 `wallet.ts`、`exchange.ts`、`worldCup.ts`、`rewards.ts`、`coinAdmin.ts` 的路由，再沿调用核对钱包、转账/打赏、红包、奖励、交易、条件单、图表、排行、赛事和管理实现。下方清单是入口映射，不表示每一种行情、赛况、网络故障都已穷举。

- 登录、用户同步、发帖统计同步改由 Discourse 原生用户和帖子数据提供，不恢复第二套登录/用户数据库。
- “创建钱包”改为首次资金操作创建；旧 JWT 接口不作为另一条资金写入通道。棋牌按用户要求排除。
- 新版后台交易检查仍为分钟任务，未实现旧 Coinbase WebSocket 与 15 秒挂单任务。不能把这一点描述为逐秒交易体验一致。
- 旧未完成挂单在切换导入时取消；保留钱包资产且不重复退款。这是已记录的迁移处理，不是继续执行旧挂单。
- 真实最终快照导入、生产正常 A/B 构建、停旧写入/启用新任务和旧入口跳转仍属于正式切换。本轮没有执行这些生产动作，也没有改生产 YAML。

## 验证

**已部署至原有私有演示入口（13001）及真实只读快照入口（13000）**。两站登录、排行、管理与顶部标签往返验收通过；快照九类资产/账务表指纹及保护开关前后一致，108 个运行代码/资源/配置文件与复核源码摘要一致。生产两个 YAML 摘要未变，生产 RSC 表仍不存在，临时测试容器已删除。

测试证据保存在私有目录 `/opt/archives/development/rsc-request-review-20260921`。先完成隔离测试，再更新两个现有私有入口；真实快照保持只读、数据源和通知关闭，更新前后核对资产表指纹。

- 共享限流测试使用真实 Redis 和独立进程，不通过实际轰击 Yahoo 制造 429。HTTP 测试模拟 429、Retry-After、网络失败和 503；验证跨标的/路径/进程冷却及拒绝无限排队。
- 真实持仓 76 个标的，冬季、夏季、春秋夏令时切换各一周，每 15 分钟一个时间点：旧运行版本与原生时段判断 **204,288 次对照，零差异**。这些时间点最多同时开市 38 个非虚拟币标的；此项是日历覆盖，不是未来行情容量保证。
- 最终隔离集成 **109 项 / 682 断言**、底层账本 **17 项 / 70 断言**通过（合计 **126 项 / 752 断言**）；另通过 12 项金额格式检查、精确估算检查及 4 项导出测试。
- 回归包含页面与后台并发合并、缓存期限、休市禁止成交、失败缓存不重标时间、止盈止损刷新、防重、失败下单审计及后台分类分页。
- 默认主题及生产核心 `b1016b1bf`、原 62 个插件加 RSC、Horizon 和 22 个组件的两轮浏览器回归通过。
- 浏览器覆盖顶部标签往返、权限隔离、手机换行，以及原有转账、红包、交易、赛事、通知、帖子打赏和管理流程。

## 旧路由入口清单

### wallet.ts

原生承接：`Wallet`、`RedPackets`、`WalletHistory`；钱包页、红包页和原生帖子打赏。

| 方法 | 旧相对路径 |
| --- | --- |
| GET | `/me` |
| POST | `/me/create` |
| GET | `/me/balance` |
| GET | `/me/transfers` |
| GET | `/me/ledger` |
| GET | `/post-tips` |
| POST | `/post-tips` |
| GET | `/red-packets/me` |
| POST | `/red-packets` |
| GET | `/red-packets/:token/public` |
| GET | `/red-packets/:token` |
| POST | `/red-packets/:token/claim` |
| POST | `/red-packets/:token/close` |
| POST | `/transfer` |

### exchange.ts

原生承接：`MarketData`、`MarketListing`、`Exchange`、`Risk`、`TradingRules`、`Reports`；股市与排行标签。

| 方法 | 旧相对路径 |
| --- | --- |
| GET | `/me` |
| GET | `/markets` |
| GET | `/chart` |
| POST | `/market-searches` |
| GET | `/market-searches/lookup` |
| GET | `/leaderboard` |
| GET | `/leaderboard/users/by-username/:username` |
| GET | `/leaderboard/users/:discourseUserId` |
| GET | `/markets/:symbol` |
| GET | `/portfolio/me` |
| POST | `/positions/:symbol/margin` |
| PUT | `/positions/:symbol/conditions` |
| GET | `/orders/me` |
| DELETE | `/orders/:orderId` |
| GET | `/trades/me` |
| POST | `/orders` |

### worldCup.ts

原生承接：`Sports`、`SportsData`；赛事标签及管理结算。

| 方法 | 旧相对路径 |
| --- | --- |
| GET | `/matches` |
| POST | `/predictions` |
| PUT | `/predictions/:predictionId` |
| POST | `/settle` |

### rewards.ts

原生承接：`Rewards`、`WalletHistory`；今日奖励和历史奖励流水。

| 方法 | 旧相对路径 |
| --- | --- |
| GET | `/me/today` |
| GET | `/me/payouts` |

### coinAdmin.ts

原生承接：`Administration`、`AdminReports`、`Catalog`、管理页；用户/活动同步由论坛原生数据替代。

| 方法 | 旧相对路径 |
| --- | --- |
| GET | `/stats` |
| GET | `/issuances` |
| POST | `/issue` |
| GET | `/wallets/lookup` |
| POST | `/wallets/:discourseUserId/ban` |
| POST | `/wallets/:discourseUserId/restore` |
| POST | `/wallets/:discourseUserId/reset-assets` |
| POST | `/rewards/preview` |
| POST | `/rewards/payout` |
| POST | `/discourse/sync-users` |
| POST | `/discourse/sync-activity` |
| POST | `/exchange/seed` |
| POST | `/exchange/quotes/sync` |
| GET | `/exchange/search-demand` |
| GET | `/exchange/market-requests` |
| GET | `/exchange/markets` |
| GET | `/exchange/markets/lookup` |
| POST | `/exchange/markets` |
| POST | `/exchange/markets/add-external` |
| POST | `/exchange/markets/remove` |
| POST | `/exchange/market-requests/approve` |
| GET | `/fund-activity` |
| GET | `/post-rewards/tips` |
| POST | `/world-cup/sync` |
| POST | `/world-cup/settle` |
| POST | `/sports-events/sync` |
| POST | `/sports-events/settle` |

本清单共 63 个业务路由；不将改名或合并后的原生 URL 误判为未迁移，也不将入口存在当作所有字段行为完全一致。
