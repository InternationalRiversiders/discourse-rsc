# 街机区：Flutter 复用与赛季

这七款目前是插件内自行实现的规则与 Canvas 2D 绘制，不是嵌入第三方成品。规则、联网回放、显示效果已分离。按目前接入目标，推荐 App 保留 Dart 的导航和登录态，用 WebView 加载服务器提供的完整小游戏页面（包含控件、样式和联网调度），不把七套规则或按键布局重新实现成 Dart。

## 当前推荐入口：远程完整游戏页面

完整入口和正式通信协议已实现，见 **[WebView 接入协议 v1](arcade-embed.md)**。

- 原生：`https://river-side.cc/rsc/arcade/embed?mode=native&game=2048`。
- Flutter Web 同源 iframe：`https://river-side.cc/rsc/arcade/embed?mode=iframe&game=2048`。
- 不传 game 显示街机入口；页面不要求论坛 cookie，实际业务请求由 App 使用自身登录态通过受限 bridge 转发。
- 论坛和独立页面共享 `arcade-app.js`、`arcade-ui.js`、`arcade-cover.js`、输入与绘制代码以及样式。Dart 不重复画方向键、手势或游戏界面。
- 服务器修改键位、触控和动画后，下次进入自动加载新版完整页面；局内不强制刷新。原生桥协议改变仍可能需要 App 更新。
- 现有 App 普通 WebView 切后台会停止脚本，不能原样套用。必须先发 pause/exit 并处理保存确认，再暂停或销毁容器。

`/rsc/games` 仍是论坛完整页面，不是独立嵌入入口。下面 SDK 方式仅为备选；接入新 App 请优先按上面的正式协议。

## 本次对照的开源实现

| 实现 | 参考点 | 本次处理 |
| --- | --- | --- |
| [2048](https://github.com/gabrielecirulli/2048)（MIT） | 移动、合并、新方块分别反馈 | 自行实现移动轨迹、合并弹出、暖色色阶与加分提示 |
| [JavaScript Tetris](https://github.com/jakesgordon/javascript-tetris)（MIT） | 输入队列与显示层分离 | 保留已有输入队列，十列实边框、格线与空心落点投影 |
| [JavaScript Snake](https://github.com/patorjk/JavaScript-Snake)（MIT） | 方向反馈、触控 | 蛇身插值、头部朝向、棋盘底色、独立障碍与食物轮廓 |
| [Floppy Bird](https://github.com/nebez/floppybird) | 拍翅和倾斜反馈 | 原创天空、云层和管道层次；不采用其声明未获授权的原作素材 |
| [Hextris](https://github.com/Hextris/hextris)（GPLv3） | 旋转过渡、消除反馈 | 只参考交互和扇形排布，自行实现梯形环与完整视野；未复制源码或素材 |
| [JavaScript Breakout](https://github.com/jakesgordon/javascript-breakout) | 触控与碰撞反馈 | 球轨迹、砖块高光、挡板与墙体区分、丢球反馈 |
| [合成大西瓜](https://github.com/liyupi/daxigua) | 落点与合成反馈 | 版本 3 加入接触摩擦、角速度和轻微弹性；固定子步、量化状态保证复算，恢复时升级存档 |

效果只读取游戏状态，不参与得分或碰撞。支持 `prefers-reduced-motion`。当前赛季直接启用版本 2，测试期历史成绩并入同一总榜与对应赛季榜。

## 交付的可复用模块

- `assets/javascripts/discourse/lib/arcade-core.js`：规则版本 3（兼容旧存档）；服务端 MiniRacer 与浏览器运行同一份。
- `arcade-playback.js`：一份在途请求、有限本地尾帧、服务端回包后重放；重试原请求。
- `arcade-effects.js` / `arcade-draw.js`：无 Ember 依赖的显示层。`arcade-sprites.js` 加载老河畔提供的 11 级素材。
- `python3 script/build-arcade-sdk.py`：生成带内容指纹的单文件 JS 和 `public/arcade/manifest.json`。
- `python3 script/build-arcade-sdk.py --check`：校验产物与源码一致。
- 发布地址：`/plugins/discourse-rsc/arcade/manifest.json`。读取 `script`，校验 `sha256` 后加载。应固定一局使用的模块版本，更新只在局外生效；旧文件不应随更新删除。

素材来自维护者提供的 [老河畔合成游戏](https://bbs.uestc.edu.cn/merge_qshp/)，保留原始 PNG、原顺序与来源/校验值，不引入老版脚本。`manifest.json` 的 `assets` 列出全部图片 URL 和 SHA256；App 可随包内置。调用 `loadMergeSprites(baseURL)` 后把返回数组赋给 `effects.sprites`，其中 `baseURL` 可以是 WebView 本地资源目录。清单建议在局外重新验证缓存，图片和 SDK 使用带指纹路径。

全局对象 `RiversideArcade` 暴露 `Core`、`Playback`、`Effects`、`draw`、`protocol`、`rulesVersion`、`loadMergeSprites`、`mergeSpriteFiles`。不是完整 Flutter 页面；App 仍需连接输入、生命周期、API 和原生导航。共享的 `arcade-app.js` 是完整调度参考，`rsc-arcade.gjs` 只负责在论坛页面挂载它。

```js
const {Playback, Effects, draw} = RiversideArcade;
const playback = new Playback(startResponse); // 服务端 start 返回的数据
const effects = new Effects({reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches});
// 固定 60Hz 逻辑帧；RAF 只决定显示，不以设备刷新率决定游戏速度。
playback.input('l');
playback.advance();
effects.observe(playback.state, playback.visualMove);
draw(canvas, playback.state, effects);
// 同时最多一份请求；网络慢时允许有限尾帧继续推进。
const request = playback.checkpoint(crypto.randomUUID());
// response = await nativeBridge.advance(playback.run.id, {...request, rules_version:3})
// playback.acknowledge(response)
```

不要在每帧调用接口。实时类通常每 120 帧同步，最多 180 帧尾缓冲；2048 使用服务端预发的最多 20 个随机数（最多约 9 步），每 4 步或停手 250ms 后同步，单批最多 16 步。完整种子不下发；预取耗尽时等待补充，不能自行生成随机值。旧版客户端需刷新或升级 SDK；服务端不再接受旧规则写入，恢复存档时直接升级并保留已验证进度。随机种子不公开，但少量前瞻及机器人策略仍可能存在；服务器复核的是规则合法性，不保证操作者是人。

## SDK 自建页面方式（备选，不满足控件自动同步目标）

以下是此前的 SDK 方案，仅在需要 App 自建完整游戏页面时采用；当前优先采用上面的远程页面方式。现有 RiversideApp 已依赖 `webview_flutter`，可参考 `lib/widgets/alumni_plugin_map.dart` 的 JavaScript channel 及 `lib/widgets/browser_frame_web.dart` 的 Web iframe 分支。

1. **Android/iOS**：本地可信 HTML + 已校验/随 App 打包的 SDK，使用 `WebViewController`；Dart 保留登录凭据，通过窄接口 bridge 代发请求。
2. **Flutter Web**：`webview_flutter` 不支持 Web；沿用 `HtmlElementView` / iframe。跨窗口消息同时验证 `event.origin`、`event.source` 和 request ID；来源不能设为 `*`。用服务端 cookie+CSRF 或同样的父页面 API 代理。
3. bridge 仅允许 `catalog`、`ranking`、`start`、`advance`，Dart 自行构造固定 API 路径。不允许 JS 传任意 URL、请求头或脚本。**不要把用户 API key 放入页面、JS、URL、日志或 postMessage。** 限制导航到可信页面，不能让任意网页复用同一鉴权 channel。
4. 消息形态建议 `{id, action, payload}`，回包 `{id, result}` 或 `{id, error}`。编码用 JSON；不要把未经编码的响应拼进 `runJavaScript`。
5. `pointerdown` 即响应，指针捕获；canvas `touch-action:none`，控制区阻止父级滚动。只屏蔽游戏区域的滚动，页面其他区域仍可滚动。保持网页已有的长按重复、快速手势队列。
6. 切后台/失焦先暂停并尝试保存，取消长按；退出前排空在途请求。断网保留原 checkpoint/request_id，不重新随机、不把本地总分作为可信成绩。恢复调用 start 取服务端存档，或重试原 checkpoint。
7. 服务端 `rules_version` 不在 SDK 支持的范围（当前正式规则为 2；Core 保留 1 用于历史回放）时暂停进入，提示更新模块；不能用不同规则继续同一局。网络慢提示“同步中”，允许已实现的本地尾帧，不把输入逐一等网络。

官方资料：[webview_flutter](https://pub.dev/packages/webview_flutter)、[Flutter Web 嵌入网页](https://docs.flutter.dev/platform-integration/web/web-content-in-flutter)。如果未来改用 [Flame](https://docs.flame-engine.org/)，建议先只替换绘制；规则重写必须先通过相同回放样例，尤其合成物理不能依赖不同运行时的浮点碰撞结果。

## API 与赛季

沿用论坛的用户鉴权和 CSRF 机制；以下不是公开任意钱包接口：

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/rsc/arcade/catalog.json` | 游戏列表、规则版本、当前轮替赛季、服务端时间 |
| GET | `/rsc/arcade/ranking.json?game=2048` | 永久 `rows`，该游戏当期 `season`，当前轮替 `featured` |
| POST | `/rsc/arcade/start.json` | `{game, request_id, rules_version:3}`；同用户同游戏恢复未过期局 |
| POST | `/rsc/arcade/:id/advance.json` | `{version, request_id, frames, events, finish, rules_version:3}`；分数由服务端计算 |

- 默认一周一个游戏，顺序：2048 → 方块堆叠 → 贪吃蛇 → 河畔飞鸟 → 六角消除 → 打砖块 → 合成大河畔。
- 后台 `rsc_arcade_rotation_cadence` 可切 `daily`；从下一期生效，不中途缩短当前赛季。默认周日北京时间 20:00 换期，日赛沿用北京时间 20:00。
- 首期给足至少六天，之后每期七天。所有游戏始终可玩，只有轮到的游戏显示赛季榜并发奖。
- 管理员与普通用户使用相同的总榜、赛季榜和奖励规则。成绩提交成功后刷新对应榜单缓存。
- 每人每游戏取最高成绩。前五名预算 100/60/40/25/15 RSC；并列平分占用名次的奖励。总榜永久保留；试玩历史不追发。
- 赛季局须在本期开始并在截止前保存。`season_id` 表示该局资格；跨期恢复的普通局仍可记入总榜，但不能进入新赛季榜。
- 截止后后台任务通常五分钟内自动结算，幂等，不能重复发奖。
- `rsc_arcade_rewards_enabled` 控制新赛季奖励快照，不追改已开始赛季。

## 验证与发布注意

`test/arcade/core.mjs`、`playback.mjs`、`effects.mjs` 覆盖 JS 规则、弱网重放、SDK一致性及显示不改分；`test/arcade_test.rb` 覆盖同样样例在服务端运行、赛季资格、并列/重复结算、周日切换。浏览器测试另覆盖触控与实际 API。

Flutter 原生包尚未集成或真机验收；后续至少测 Android WebView、iOS WKWebView、Flutter Web 各一套，尤其触控抢占、后台恢复、丢回包重试、版本升级、弱网 2048 预取耗尽、补充、重试与飞鸟。

## 无尽规则与存档

- 版本 2 取消全部游戏的倒计时、2048 步数、方块数量、合成投放次数限制。打砖块清屏换关、增加球速和砖块耐久；飞鸟、六角、方块渐进提速。失败条件仍由服务器模拟。
- 合成使用固定逻辑尺寸、两次子步与稳定碰撞顺序，空间桶减少碰撞候选对。不使用客户端时间决定运动。左右投放范围按当前图案半径计算。客户端只能提交输入，不能提交物体坐标或分数。
- 手机优先在画面内操作：2048、贪吃蛇滑动，飞鸟轻点，合成选点投放，打砖块拖动。方块堆叠与六角消除的触控键收进画面底部独立控制栏，不遮挡有效游戏区域；桌面有鼠标时隐藏控制栏，使用键盘。打砖块接受 x:0..4000 目标输入，挡板依然按每帧最大 65 单位移动，拖动不允许瞬移。支持多指指针捕获。
- 存档每次有效操作后保留 30 天。每 64 批次折叠为服务器权威检查点及摘要链，后续批次从该检查点重放；历史完整逐帧输入不再无限保留，不能据此声称可重放整局。每个批次依然完整校验。未同步的本地尾帧在页面被系统强杀时可能丢失。
- 新版赛季在截止时自动计入最后已同步的检查点；截止后的输入不会追加分数。总榜无奖金；赛季排名仍只计当期开始的局。其他游戏存档可以跨期继续，但不进入新赛季。
- 当前赛季直接使用新版规则；历史测试成绩并入总榜和相应赛季。旧存档恢复时保留服务器已验证的状态、分数，升级规则并增加修订号，创建新的权威检查点。旧客户端须刷新，不再新开旧规则对局。

## 发布兼容性

唯一数据库修改是 score integer 扩为 bigint，保留全部列和历史数据，旧版本可读取。迁移设 3 秒锁等待上限，失败就停止发布，不能在共享数据容器上重启服务。

先在隔离环境验证迁移和新旧存档回放，再从一次性候选镜像任务运行该单一迁移；完成后按 A/B 流程启动、校验、切换、排空。切换前确认当前赛季不在截止窗口，避免旧结算器处理新规则。新镜像保留旧指纹资源；旧客户端收到更新提示后须刷新，避免不同规则继续同一局。

一旦创建了版本 2 存档，回滚到不认识版本 2 的镜像前必须先设置 rsc_read_only=true 并关闭 rsc_arcade_enabled，暂停所有 RSC 写操作和自动结算（旧版本的结算器不会仅因关闭街机入口而停止）。新旧存档和奖金快照保留，不删成绩、不清空奖池；修复后恢复支持版本 2 的服务，再恢复原开关。数据库 bigint 不回退。

## 2026-11-08 手感调整

- 贪吃蛇和方块使用画面内倒 T 形方向键；方块硬降在右侧独立放置。网页和嵌入页共享布局。
- 飞鸟版本 3 使用内缩椭圆碰撞体，管口边角按最近点检测；鸟嘴、翅膀不计入碰撞体。参考 [Floppy Bird 的碰撞框修正](https://github.com/nebez/floppybird/blob/gh-pages/js/main.js)，没有复制其图片或源码。
- [老河畔合成游戏](https://bbs.uestc.edu.cn/merge_qshp/) 的 `src/project.js` 使用 Cocos `PhysicsManager` / `RigidBody`，重力配置为 `(0,-300)`；引擎包含 `b2World`。本插件没有直接嵌入其物理引擎，采用共享确定性圆体求解，新增接触摩擦、角速度、旋转绘制与小幅弹性，避免只消除重叠带来的僵硬感。
- 当前规则为 3，桥协议仍为 1。服务端兼容已打开的规则 2 页面；新版恢复旧局时保留位置/得分、升级检查点并递增版本，旧页面不得继续写入已升级局。排名不清空。
