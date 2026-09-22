# 验证方式

本机使用已有的 `local_discourse/web_a:latest` 镜像提供与线上相同版本的 Ruby/Discourse 依赖。测试使用新建的 `--network none` 容器、独立 PostgreSQL 和 Redis，不挂载线上数据库或共享目录；插件目录只读挂载为 `/rsc`。

## 后端

```sh
bash test/run-isolated.sh
```

脚本自动创建并清理临时容器。可用 `RSC_DISCOURSE_IMAGE` 指定另一个具备依赖的 Discourse 镜像。脚本需要 Docker 权限；当前用户无法访问 Docker 时尝试 `sudo -n docker`。

- `accounting_test.rb` 使用真实 PostgreSQL，验证金额精度、并发超支、请求重放、回滚与数据库历史保护。只接受 `rsc_native_test` 测试库，会重建其中的 RSC 表。
- `discourse_smoke.rb` 使用论坛真实用户、用户组、权限、路由、HTTP 请求和通知模型。
- `business_test.rb` 加入红包并发领取、随机金额守恒、预测锁赔率/修改/结算、冻结退款、股市预留/成交/撤单/过期/价格保护/强平/止盈、每日奖励及私有流水隔离。

- `migration_features_test.rb` 加入高风险模式与冷却、组合限额、追加保证金、管理审计及权限、真实数据源响应、加时赛果、历史归属，以及钱包/持仓/预测/红包的导入回滚和对账。

`prepare_disposable_forum.sh` 仅供全新临时容器使用：它初始化容器内 PostgreSQL/Redis 和测试论坛，替换容器内插件目录，运行基础与业务集成测试。不要在现有论坛容器或宿主机执行。完整镜像需要 PostgreSQL、pgvector、Redis、已安装 Ruby 依赖及 Discourse `db/structure.sql`。测试脚本自动选择镜像内的 PostgreSQL 服务端版本，并保留已安装的 RSC WebSocket gem，以便完全断网运行。

2026-09-20：账本 17 个测试 / 70 项断言，Discourse 集成 44 个测试 / 252 项断言，合计 **61 个后端测试 / 322 项断言通过**。新增缺失账号预检、批量历史、防重记录、演练子集保护，以及跨批次期初入账的精度和整批回滚检查。

`python3 test/export_legacy_test.py` 的 4 个独立测试验证只读导出、金额字符串精度、世界杯活动历史、输出文件权限、防覆盖，以及拒绝遗漏新业务表或未结算棋牌游戏资金。

## 浏览器与截图

```sh
RSC_PLAYWRIGHT=/absolute/path/to/node_modules/playwright \
RSC_CHROMIUM=/absolute/path/to/chrome \
RSC_BROWSER_OUTPUT=/tmp/rsc-browser-artifacts \
bash test/run-browser-isolated.sh
```

需要本机已安装 Playwright、Chromium、Docker 和 `sudo -n nsenter` 权限。脚本从新容器开始，运行集成测试，用 Discourse 自身构建器编译插件和样式，再启动测试论坛。宿主机浏览器仅进入该容器的网络命名空间；不会把端口发布到公网。结束时清理容器和临时凭据，保留截图。

`seed_browser.rb` 只接受隔离测试库，清空该库的 RSC 表并创建明确标注的演示行情、比赛和测试资金。`demo_tick.rb` 只刷新标记为 `demo` 的行情并驱动订单/通知；它不属于生产插件任务，不发起外部行情请求。

`browser.cjs` 使用真实用户名密码登录和 Discourse CSRF，不拦截或伪造 RSC 接口响应。验证流程：

1. 打开原生钱包并提交转账。
2. 创建红包，在原生红包页面收回剩余资金。
3. 检查行情分类、搜索、排序、分页和详情联动；验证过期报价禁用下单、缺失昨收不显示虚假涨跌。提交委托，等待成交并显示持仓。
4. 打开论坛头像菜单，验证成交通知及其股市链接。
5. 提交赛事预测，查看预测记录。
6. 1440 像素桌面和 390 像素手机宽度截图；验证手机默认行情列表、进入详情与返回，检查没有整页横向溢出。
7. 打开真实论坛帖子，通过帖子菜单按钮和原生弹窗完成打赏。
8. 验证多周期/K 线切换、追加保证金、排行榜、完整流水、打赏后汇总即时更新。
9. 普通用户管理接口被拒绝；管理员通过真实会话新增标的、查看审计，在桌面/手机截图。
10. 断言没有页面 JavaScript 运行时错误。

截图保存在 [docs/screenshots](../docs/screenshots)。隔离镜像未配置完整外部头像、WebAuthn 和外部资源访问，可能出现论坛核心头像或外部资源加载错误；不影响上述 RSC 流程，不能将其视为生产主题环境的完整验收。

公开行情响应已作只读检查和离线回归；合成资产及真实可映射账号子集已完成导入演练、对账，真实子集还验证了备份恢复，详见 [真实数据演练](../docs/real-data-rehearsal.md)。尚未完成付费数据源套餐联调、含缺失身份的真实全量资产导入、线上主题/其他插件组合和长期运行验收。测试通过不代表生产已经切换。

调试时可设置 `RSC_KEEP_TEST_CONTAINER=1` 保留独立容器及日志；验收后需删除该测试容器和私有临时凭据。默认执行会自动清理。

`readiness_test.rb` 额外验证只读拦截、生命周期/数据库所有者保护、分页、批量报表、历史收益因子、活动补发防重及回滚、76 个持仓行情覆盖、历史 K 线只读恢复。已部署的私有演示站是明确保留供用户测试的例外，见 [连接说明](../docs/private-testing.md)。

Display parity regressions: `node test/format_test.mjs` checks decimal truncation without floating-point conversion. `test/verify_behavior_parity.rb` compares seven leaderboard sorts and the full market order against the old backend output from the same snapshot; it refuses to run outside the private read-only snapshot database. See `docs/behavior-parity.md`.

## 2026-09-21 原生适配回归

`native_adaptation_test.rb` 加入持仓/撤单窗口、保护价、冻结持仓、追加保证金、流动性、未来豁免、通知定位、公开汇总权限、合并流水分页及归属、老比赛、旧申请/订单元数据和不重复记账。默认后端脚本已包含。

`node test/estimate-test.mjs` 以 BigInt 验证三类成交模式的数量边界，不以浮点数提交资金。新增浏览器检查包括统一流水、通知实际导航及离开后的手机列表恢复。旧打赏组件共存和六插件私有入口检查的具体结果见 [适配记录](../docs/native-adaptation-2026-09-21.md)；脚本默认新建论坛只安装 RSC，不能冒充生产完整插件组合测试。

## 访问与奖励回归（2026-09-21）

`access_review_test.rb` 随默认隔离脚本执行，覆盖管理/使用权限独立、取消成员资格、停用/封禁管理员、空钱包读取、只读奖励预览不产生账户或分录、GET 的 pay 参数不能付款、登录奖励的 UTC+8 日期边界及访问时间回退。本轮 17 项账本测试（70 断言）与 69 项 Discourse 集成测试（390 断言）通过，总计 86 项、460 断言。

The manual public-provider probes now require `RSC_PROBE_REDIS_URL` pointing to a
**disposable** Redis, in addition to `RSC_PUBLIC_PROVIDER_PROBE=1`. They exercise
the same shared pacing/cooldown as the plugin; never point a standalone probe at
production Redis. Provider-failure tests use simulated HTTP responses with real
isolated Redis/processes instead of sending traffic to provoke provider bans.

## 手机持仓与导航回归（2026-09-21）

`mobile-layout.cjs` 由浏览器流程在已有合成持仓后调用，覆盖 320–1440 像素的九种宽度，包括旧版会将指标挤到 5–10 像素宽的中间尺寸。验证持仓可读、页面无横向溢出、手机导航不被论坛页头遮挡，以及滚到底部后使用实际屏幕坐标切换股市/赛事，无整页重载。独立验证同时加载了线上公开的主题样式，并覆盖管理员的五个导航入口。

修复只涉及布局：持仓信息、平仓和风控表单分行；手机导航在论坛页头下方吸顶，自动换行；RSC 页面使用 CSS 抑制浏览器越界下拉刷新，不拦截正常触摸滚动。浏览器自动化使用 Chromium；iOS Safari 和 App 外层 WebView 的原生刷新行为仍需真机确认。

## 紧凑布局与最近流水回归（2026-09-22）

`compact-browser.cjs` 覆盖浅色/深色下 1440、1024、768、390、320 像素宽度：桌面奖励四列、赛事三个筛选和排行榜查询排序保持同一行；页面无横向溢出；流水首屏 20 条、连续加载无重复、隐藏迁移期初项；平仓盈亏正负号与颜色、开仓不显示已实现盈亏、紧凑行高、折叠详情、筛选和查询功能，以及新转账完成后流水即时更新。

只在 `prepare_disposable_forum.sh` 创建的隔离论坛中，先运行 `seed_browser.rb`，再运行 `seed_compact_browser.rb` 添加合成历史与盈亏记录。浏览器脚本使用与 `browser.cjs` 相同的 `RSC_PLAYWRIGHT`、`RSC_CHROMIUM`、`RSC_BROWSER_CREDENTIALS`、`RSC_BROWSER_OUTPUT` 环境变量及隔离网络命名空间。测试数据不来自生产用户。

`native_adaptation_test.rb` 的统一流水测试同时验证 20 条和原有 50 条分页、跨新旧记录的游标连续性、权限，以及隐藏期初项不修改账本和余额；`format_test.mjs` 验证带正负号的金额仍以十进制字符串截断。

## 赛事队徽与中文名称（2026-09-22）

`sports_presentation_test.rb` 验证 ESPN 的 logo/logos 两种字段、缺图时保留上次队徽、图片域名限制、中文/英文显示及未知球队回退，以及从 LegacyRecord 恢复历史队徽的幂等性。恢复仅更新 provider_data，不调用赛事同步或结算，不改赔率、赛果、预测及账本。

`sports-browser.cjs` 在隔离论坛运行：先执行 `seed_browser.rb` 和 `seed_sports_browser.rb`。验证图片成功/失败占位、中文与英文原名、未知队名，以及两种配色下 320/390/768/1440 像素的布局。仅外部图片请求用固定图片和故障响应替代；论坛 API 为真实请求。实际 ESPN 队徽另作只读 HTTP 检查。

中文名称表位于 `config/sports_names.zh_CN.json`，不调用翻译服务。新增球队可补充该表；未收录名称保留原文。数据源原始队名不改，中文展示跟随论坛当前语言。

## 红包分享与浏览器时区（2026-09-22）

`node test/campus-time-test.mjs` 检查六个独立插件内的日期工具保持一致，覆盖上海、纽约夏令时/冬令时、UTC、缺失或无效时区、缺失 Intl、无偏移的历史时间和纯日期。展示跟随浏览器时区，无法识别时回退 UTC+8；每日奖励和 RS Date 定时发布的业务时区不变。

`packet_sharing_test.rb` 随隔离后端测试执行，验证原生与旧域名红包链接无需外网即可生成 Onebox，文本转义、公开元数据、未知红包 404，以及生成卡片不修改账本、领取记录或暴露领取明细。

`packet-time-browser.cjs` 需在同时安装六个校园插件的隔离论坛中运行，使用合成账户和各插件示例内容；最后运行 `seed_packet_browser.rb`，将生成的 `/tmp/campus-packet-browser.json` 作为 `RSC_BROWSER_CREDENTIALS`。验证三种浏览器时区、320/390/1440 像素和两种配色下的紧凑红包页、实际领取、各插件时间展示，以及帖子内新旧两类链接的真实 Onebox。树洞和觅电保留相对时间，悬停提示显示本地绝对时间。不要对生产数据库运行种子脚本。

## 股市工作台（2026-09-22）

`trading_workspace_test.rb` 已加入默认隔离后端流程。`workspace-browser.cjs` 在基础 `seed_browser.rb` 后使用 `seed_workspace_browser.rb` 与 `seed_workspace_ranking.rb`，并启动 `demo_tick.rb` 保持合成行情有效。脚本测试真实逐字输入、自动刷新和资金操作，不伪造股市 API。可用 `RSC_BROWSER_THEME` 指向公开主题 CSS 文件，在隔离站追加验证线上样式。完整改动、字段口径和验证范围见 [工作台记录](../docs/trading-workspace-2026-09-22.md)。
