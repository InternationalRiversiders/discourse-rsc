# 街机区 WebView 接入协议（v1）

## 入口和分工

- 原生 Android/iOS：`https://river-side.cc/rsc/arcade/embed?mode=native`
- 直接打开某个游戏：再加 `&game=2048`（或 `blocks`、`snake`、`bird`、`hex`、`bricks`、`merge`）。不传 game 则显示七款游戏入口和赛季横幅。
- 同站 Flutter Web `/app/`：iframe 使用同一 URL，改成 `mode=iframe`。仅支持同源父页面，跨域宿主不在本协议内。
- 发布清单：`https://river-side.cc/plugins/discourse-rsc/arcade/embed-manifest.json`。记录协议、规则版本、JS/CSS 指纹和校验值。App 应加载稳定入口，不固定清单中的某一版脚本。

独立入口无论坛页头/侧栏、无凭据、无用户资料预加载。关闭 RSC 或街机功能时返回 404。HTML 响应为 `Cache-Control: no-store`；它引用的 JS/CSS 使用内容指纹。页面不直接请求业务 API，使用宿主桥接。整个游戏界面、触控、按键、布局、动画、排行榜、存档调度由服务器发布，论坛和嵌入页使用同一份 `arcade-app.js`、`arcade-ui.js`、绘制模块及 `rsc-arcade.scss`。

普通浏览器直接打开原生入口会停在“正在连接游戏”，直到 App 完成握手；网页试玩仍使用 `/rsc/games`。

Flutter 只做 WebView 容器、导航、安全区、鉴权请求代理和生命周期。不要在 Dart 再画方向键、把手势转成游戏指令或注入布局补丁。宿主控制安全区，网页只保留常规内边距；容器不要抢游戏区的滑动和长按。

此入口只包含七款街机游戏。博弈区和大乐透继续使用它们现有接口，不允许通过本桥任意调用钱包或下注 API。

## 建立连接

Android/iOS 在加载页面前注册名为 **`RiversideArcadeChannel`** 的 JavaScript channel。页面发往原生：

```js
window.RiversideArcadeChannel.postMessage(JSON.stringify(message));
```

原生发往页面：

```js
window.RiversideArcadeHost.receive(message);
```

Flutter 的 `runJavaScript` 应用 `jsonEncode(message)` 生成参数，不能字符串拼接用户文本、URL 或响应正文。可以传 JSON 对象或 JSON 字符串。

Flutter Web 由父页面和 iframe 使用 `postMessage`。两端 targetOrigin 都是论坛的精确 origin；父页面须同时验证 `event.origin` 和 `event.source === iframe.contentWindow`。不要使用 `*`。iframe 模式不接受原生 receive 方法的消息。

每次文档加载会生成新的随机 `session`，不是用户凭据。每条消息共同包含：

```json
{"channel":"riverside.arcade","protocol":1,"session":"本次文档生成的 UUID","type":"..."}
```

页面就绪时发送 `type: "ready"`，另含 `rules_version: 4`、`actions: ["catalog","ranking","start","advance"]`、`commands: ["pause","resume","exit","theme"]`。收到初始化前约每秒重发一次，宿主不要因重发而重复创建容器。

宿主按 protocol 检查桥接协议兼容性；rules_version 是网页与服务器的游戏规则版本，保存当前 ready 声明值用于请求校验，不能把它当作 App 支持的游戏规则白名单。然后原样带回该 session：

```json
{"channel":"riverside.arcade","protocol":1,"session":"从 ready 取得","type":"init","payload":{"theme":"auto"}}
```

theme 可为 `auto`、`light`、`dark`。页面只初始化一次，回复 `type: "initialized", rules_version: 4`。之后自动加载目录；指定 game 时也会读取榜单。**initialized 仅表示协议已建立，不代表已登录或 API 请求成功。** 协议不兼容时宿主应显示更新提示，不继续发送游戏请求。

单游戏嵌入页（入口带有效 game）默认由 App 提供标题栏和返回按钮，网页省略自己的标题和“返回挑战”，并固定当前游戏，不再进入网页内部大厅。无需额外初始化开关。App 顶部显示该游戏名称；返回仍通过既有 `exit` 命令等待 `saved: true` 后关闭容器。未指定 game 的嵌入大厅和普通论坛页面保留原有导航；不改变协议版本、鉴权或保存流程。

宿主只能接受当前可信顶层文档发出的消息。限制加载 URL 的 scheme、host、port、path，阻止非可信跳转/新窗口，不能只做字符串前缀匹配；禁止同一桥被任意网页复用。嵌入页面 CSP 不允许子 frame 和直接业务网络请求。

## 四个业务 action

页面发送：

```json
{"channel":"riverside.arcade","protocol":1,"session":"...","type":"request","id":"消息 UUID","action":"ranking","payload":{"game":"2048"}}
```

宿主自行构造固定路径，并使用 App 已有登录用户的鉴权方式请求论坛。这里的 `id` 用于桥接关联；`payload.request_id` 才是后端写操作的幂等键，两者不能混用。

| action | 方法和路径 | payload |
| --- | --- | --- |
| catalog | GET `/rsc/arcade/catalog.json` | `{}` |
| ranking | GET `/rsc/arcade/ranking.json?game=游戏ID` | `{game}` |
| start | POST `/rsc/arcade/start.json` | `{game, request_id, rules_version:4, scope:"all"或"season"}` |
| advance | POST `/rsc/arcade/:id/advance.json` | `{id, version, request_id, frames, events, finish, rules_version:4}`；id 只用于路径，不必放入 HTTP body |

宿主必须独立校验 action、游戏 ID、数据类型与数量边界，忽略/拒绝额外请求字段。参考可执行白名单 `assets/javascripts/discourse/lib/arcade-transport.js`：

- id 是正的安全整数，version 为非负整数；request_id 是 1–100 字符的字符串。
- frames 为 0–180 的整数，events 最多 360 条，每条 `[帧号, 指令]`，帧号在 `[0, frames)`。
- 指令仅 `l/r/u/d/drop/tap/x:0..4000`；finish 必须为 boolean；规则版本当前为 4。原生端应校验它与当前可信页面 ready 消息声明的 rules_version 相同，不要在 Dart 写死具体规则版本；本规则字段变动不等于 bridge 协议变动。
- 服务端另按游戏校验输入和批次限制（2048 单批最多 16 步），仍是最终裁决者。不能提交分数、坐标、随机种子或修改后的状态。
- 不接受网页传入任意 URL、请求方法、鉴权请求头、账号或钱包目标。

成功回包：

```json
{"channel":"riverside.arcade","protocol":1,"session":"...","type":"response","id":"请求消息 UUID","result":{"此处":"完整原始 API JSON 对象"}}
```

失败回包：

```json
{"channel":"riverside.arcade","protocol":1,"session":"...","type":"response","id":"请求消息 UUID","error":{"message":"服务端中文错误或清晰的网络错误","code":"可选业务码","status":403}}
```

API 的错误响应必须转成 `error`，不能作为成功的 result。不把鉴权请求头、key、完整调试堆栈塞进 message。页面单个桥接请求约 15 秒超时；宿主应及时返回失败，不长期悬挂请求。一次只会有一个游戏进度请求在途，目录/排名可能并行。宿主不要按游戏帧频发送 HTTP 请求。

页面保留失败 checkpoint；用户重试时桥接消息 ID 可以更新，但后端 request_id 和请求 body 不变。宿主不得替换 request_id、改 frames/events 或额外调用 start。丢失回包不等于服务端未保存。已超时/旧 session 的回包必须丢弃。

## 暂停、保存、恢复和退出

宿主向页面发 command，id 为宿主自己的唯一消息 ID：

```json
{"channel":"riverside.arcade","protocol":1,"session":"...","type":"command","id":"pause-123","action":"pause","payload":{}}
```

| action | 行为 |
| --- | --- |
| pause | 立即暂停输入、释放长按，等待正在 start 的请求，再排空 checkpoint；不结束本局 |
| resume | 重试未确认 checkpoint，读取服务器进度，保持暂停状态，用户点击继续；不擅自丢弃未确认操作 |
| exit | 先执行暂停保存；成功后禁用页面输入，宿主才关闭 WebView |
| theme | payload `{theme:"light"或"dark"或"auto"}`，只改显示 |

保存回执：

```json
{"channel":"riverside.arcade","protocol":1,"session":"...","type":"command-result","id":"pause-123","result":{"saved":true,"run_id":123,"version":8,"status":"playing"}}
```

保存失败为 `result.saved:false` 并有 `result.error`；命令自身不适用时为顶层 `error.message`。没有开始对局时 run_id/version/status 可为 null。theme 回复 `result.ok:true`。宿主须同时处理这两种失败，不能见到 command-result 就当作保存成功。

- 用户返回：发 exit，等 saved:true 后退出。失败或超时让用户选择重试或放弃未同步部分；不要显示“已保存”。重试失败的命令使用新 id；相同 id+相同内容会返回同一次命令的结果。最近 64 个命令去重。
- App 即将失焦/切后台：尽早发 pause，允许请求完成。不能先 `window.stop()`、禁用 JavaScript 或销毁 WebView。系统强杀无法保证回执，服务器已确认的进度仍可恢复。
- 回到前台：发 resume，保持手动继续。不要自动刷新文档；刷新会丢失尚在内存的未确认操作。
- 切换账号/登出：先暂停保存，再销毁旧文档与桥；清理旧 pending 请求/回包，重新建立新 session，绝不能把旧局请求用新账号发出。
- 页面自身也会在 visibilitychange/blur/pagehide 时尝试暂停，但原生生命周期通知仍需要接入。
- 页面点击榜单用户时可发 `{type:"profile", username:"..."}`；宿主可打开原生名片，用户名必须编码后构造固定用户路径。这是可选事件，不是任意 URL 导航。

## 自动更新与验收

每次新打开 WebView 读取稳定入口，即加载服务器当前的完整游戏 UI。局内不热替换脚本；旧指纹资源保留。普通键位/触控/样式/动画调整不要求 App 发版；原生能力和 bridge 协议不兼容变更仍需 App 配合。服务端规则升级仍须遵守存档兼容策略，不能仅因保留旧资源就保证旧写协议可用。

插件构建：`python3 script/build-arcade-embed.py --sass /path/to/dart-sass/sass`，加 `--check` 验证构建产物。正常的 `assets:precompile:build_plugins` 和 `assets:precompile` 已接入自动构建任务，会同步生成嵌入页，不需要额外手工维护一套产物。完整论坛前端仍须正常编译；线上按 A/B 发布。只修改有指纹的产物而不更新源码不受支持。

至少验收 Android WebView、iOS WKWebView、Flutter Web：七款触控、长按释放、多指、横竖屏/安全区、后台和返回保存、离线/丢回包后原请求重试、会话/账号切换、排名刷新、资源更新和协议不兼容。

仓库包含 `test/arcade/bridge.mjs` 和 `test/arcade-embed-browser.cjs`，后者用独立且无登录 cookie 的页面模拟原生宿主，通过另一会话转发真实 API，验证页面不需要拿到用户凭据。浏览器模拟不等于 Flutter 真机验收。
