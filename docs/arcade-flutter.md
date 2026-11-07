# 休闲挑战：Flutter 复用与赛季

这七款目前是插件内自行实现的规则与 Canvas 2D 绘制，不是嵌入第三方成品。规则、联网回放、显示效果已分离。推荐 App 保留 Dart 的导航和登录态，用 WebView 运行相同 JS；不把七套规则重新实现成 Dart。

## 本次对照的开源实现

| 实现 | 参考点 | 本次处理 |
| --- | --- | --- |
| [2048](https://github.com/gabrielecirulli/2048)（MIT） | 移动、合并、新方块分别反馈 | 自行实现移动轨迹、合并弹出与加分提示 |
| [JavaScript Tetris](https://github.com/jakesgordon/javascript-tetris)（MIT） | 输入队列与显示层分离 | 保留已有输入队列，增加落点投影 |
| [JavaScript Snake](https://github.com/patorjk/JavaScript-Snake)（MIT） | 方向反馈、触控 | 蛇身插值、头部朝向、进食反馈 |
| [Floppy Bird](https://github.com/nebez/floppybird) | 拍翅和倾斜反馈 | 原创 Canvas 图形；不采用其声明未获授权的原作素材 |
| [Hextris](https://github.com/Hextris/hextris)（GPLv3） | 旋转过渡、消除反馈 | 只参考交互，自行实现动画；未复制源码或素材 |
| [JavaScript Breakout](https://github.com/jakesgordon/javascript-breakout) | 触控与碰撞反馈 | 球轨迹、碎块、丢球反馈 |
| [合成大西瓜](https://github.com/liyupi/daxigua) | 落点与合成反馈 | 自有整数物理保持不变，增加瞄准线与合成反馈 |

效果只读取游戏状态，不参与得分或碰撞。支持 `prefers-reduced-motion`。尚未加入改变规则的旋转踢墙、物理引擎替换等内容，避免总榜的历史成绩失去可比性。

## 交付的可复用模块

- `assets/javascripts/discourse/lib/arcade-core.js`：规则版本 1；服务端 MiniRacer 与浏览器运行同一份。
- `arcade-playback.js`：一份在途请求、有限本地尾帧、服务端回包后重放；重试原请求。
- `arcade-effects.js` / `arcade-draw.js`：无 Ember 依赖的显示层。
- `python3 script/build-arcade-sdk.py`：生成带内容指纹的单文件 JS 和 `public/arcade/manifest.json`。
- `python3 script/build-arcade-sdk.py --check`：校验产物与源码一致。
- 发布地址：`/plugins/discourse-rsc/arcade/manifest.json`。读取 `script`，校验 `sha256` 后加载。应固定一局使用的模块版本，更新只在局外生效；旧文件不应随更新删除。

全局对象 `RiversideArcade` 暴露 `Core`、`Playback`、`Effects`、`draw`、`protocol`、`rulesVersion`。不是完整 Flutter 页面；App 仍需连接输入、生命周期、API 和原生导航。论坛现有 `rsc-arcade.gjs` 是可运行的完整调度参考。

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
// response = await nativeBridge.advance(playback.run.id, request)
// playback.acknowledge(response)
```

不要在每帧调用接口。实时类通常每 120 帧同步，最多 180 帧尾缓冲；2048 每步需服务端新方块，可以排队手势，不能自行猜下一块。随机种子不公开，但少量前瞻及机器人策略仍可能存在；服务器复核的是规则合法性，不保证操作者是人。

## App 集成方式

现有 RiversideApp 已依赖 `webview_flutter`，可参考 `lib/widgets/alumni_plugin_map.dart` 的 JavaScript channel 及 `lib/widgets/browser_frame_web.dart` 的 Web iframe 分支。

1. **Android/iOS**：本地可信 HTML + 已校验/随 App 打包的 SDK，使用 `WebViewController`；Dart 保留登录凭据，通过窄接口 bridge 代发请求。
2. **Flutter Web**：`webview_flutter` 不支持 Web；沿用 `HtmlElementView` / iframe。跨窗口消息同时验证 `event.origin`、`event.source` 和 request ID；来源不能设为 `*`。用服务端 cookie+CSRF 或同样的父页面 API 代理。
3. bridge 仅允许 `catalog`、`ranking`、`start`、`advance`，Dart 自行构造固定 API 路径。不允许 JS 传任意 URL、请求头或脚本。**不要把用户 API key 放入页面、JS、URL、日志或 postMessage。** 限制导航到可信页面，不能让任意网页复用同一鉴权 channel。
4. 消息形态建议 `{id, action, payload}`，回包 `{id, result}` 或 `{id, error}`。编码用 JSON；不要把未经编码的响应拼进 `runJavaScript`。
5. `pointerdown` 即响应，指针捕获；canvas `touch-action:none`，控制区阻止父级滚动。只屏蔽游戏区域的滚动，页面其他区域仍可滚动。保持网页已有的长按重复、快速手势队列。
6. 切后台/失焦先暂停并尝试保存，取消长按；退出前排空在途请求。断网保留原 checkpoint/request_id，不重新随机、不把本地总分作为可信成绩。恢复调用 start 取服务端存档，或重试原 checkpoint。
7. 服务端 `rules_version` 与 SDK 不匹配时暂停进入，提示更新模块；不能用不同规则继续同一局。网络慢提示“同步中”，允许已实现的本地尾帧，不把输入逐一等网络。

官方资料：[webview_flutter](https://pub.dev/packages/webview_flutter)、[Flutter Web 嵌入网页](https://docs.flutter.dev/platform-integration/web/web-content-in-flutter)。如果未来改用 [Flame](https://docs.flame-engine.org/)，建议先只替换绘制；规则重写必须先通过相同回放样例，尤其合成物理不能依赖不同运行时的浮点碰撞结果。

## API 与赛季

沿用论坛的用户鉴权和 CSRF 机制；以下不是公开任意钱包接口：

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/rsc/arcade/catalog.json` | 游戏列表、规则版本、当前轮替赛季、服务端时间 |
| GET | `/rsc/arcade/ranking.json?game=2048` | 永久 `rows`，该游戏当期 `season`，当前轮替 `featured` |
| POST | `/rsc/arcade/start.json` | `{game, request_id}`；同用户同游戏恢复未过期局 |
| POST | `/rsc/arcade/:id/advance.json` | `{version, request_id, frames, events, finish}`；分数由服务端计算 |

- 默认一周一个游戏，顺序：2048 → 方块堆叠 → 贪吃蛇 → 河畔飞鸟 → 六角消除 → 打砖块 → 合成大河畔。
- 后台 `rsc_arcade_rotation_cadence` 可切 `daily`；从下一期生效，不中途缩短当前赛季。默认周日北京时间 20:00 换期，日赛沿用北京时间 20:00。
- 首期给足至少六天，之后每期七天。所有游戏始终可玩，只有轮到的游戏显示赛季榜并发奖。
- 每人每游戏取最高成绩。前五名预算 100/60/40/25/15 RSC；并列平分占用名次的奖励。总榜永久保留；试玩历史不追发。
- 赛季局须在本期开始并在截止前保存。`season_id` 表示该局资格；跨期恢复的普通局仍可记入总榜，但不能进入新赛季榜。
- 截止后后台任务通常五分钟内自动结算，幂等，不能重复发奖。
- `rsc_arcade_rewards_enabled` 控制新赛季奖励快照，不追改已开始赛季。

## 验证与发布注意

`test/arcade/core.mjs`、`playback.mjs`、`effects.mjs` 覆盖 JS 规则、弱网重放、SDK一致性及显示不改分；`test/arcade_test.rb` 覆盖同样样例在服务端运行、赛季资格、并列/重复结算、周日切换。浏览器测试另覆盖触控与实际 API。

Flutter 原生包尚未集成或真机验收；后续至少测 Android WebView、iOS WKWebView、Flutter Web 各一套，尤其触控抢占、后台恢复、丢回包重试、版本升级、弱网 2048 与飞鸟。

本次 schema 是加字段/索引，旧版本可短暂共存；但旧版本按七款分别派奖。首次上线时先保持奖励关闭，等旧槽位后台任务排空后才启用新赛季奖励并设置首期快照。若回滚到旧版本，先关闭奖励并清空尚未结算的新赛季奖励快照，再恢复旧任务，防止旧结算器将单赛季预算用于七款游戏。
