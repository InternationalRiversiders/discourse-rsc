# 游戏 3D 动画

2026-11-07。六个游戏全部使用 WebGL（three.js）实时渲染；大厅封面同样由 3D 场景生成。

| 内部 id | 显示名称 | 3D 表现 |
| --- | --- | --- |
| slots | 转转乐 | 三个弧形转轴，高速运动模糊，逐个回弹停下 |
| roulette | 幸运转盘 | 木质转盘与金属品格（加宽数字环、大号数字、更俯视的镜头），球沿轨道下落、跳格、入袋，开奖格发光 |
| scratch | 刮刮乐 | 浮动倾斜的票面，金属涂层可直接用鼠标/手指刮开，碎屑掉落，中奖格发光 |
| blackjack | 21点 | 牌桌、发牌器和筹码；牌从发牌器飞出并翻面，庄家暗牌翻开 |
| coin | 抛硬币 | 仿清水河畔徽标：金色外圈与深蓝珐琅面，正面直立金色银杏叶，反面多面折纸白船；抛起、落地、摇摆停稳 |
| dice | 猜骰子 | 象牙色圆角骰子（凹陷亮面点数）掷入圆形木框毛毡盘，弹跳翻滚后停在结果点数 |

前端显示名称与服务器 `Games::NAMES` 保持一致；已写入的历史流水说明不回写。规则、赔付和结算均未改变。

## 结构

- `lib/game-3d-scenes.js`：所有场景（three 由调用方注入）。终态只由回合 `id`、`version` 与服务器 `state` 推导，动画结束画面与之后查看历史的静态画面一致。
  - 公共 `Stage`：按需渲染；空闲时镜头缓慢漂移、鼠标视差，转盘慢转、硬币高光移动（约 30 fps，页面隐藏或不在视口内时停止）。
  - 获胜后抛出金币粒子；首次显示前用 `compileAsync` 预编译着色器并渲染一帧预热，避免第一次开奖卡顿。
- `lib/game-3d.js`：检测 WebGL 2，运行时从 `/plugins/discourse-rsc/javascripts/rsc-three-0.186.1-b2.js` 动态加载（约 138 KB gzip），大厅空闲时预取。生产对 `/plugins` 缓存一年，重新打包必须改文件名后缀。
- 大厅封面：`public/images/games/cover-<game>-<vN>.webp`，由 `script/render-game-covers.cjs` 用同样的 3D 场景离线渲染（硬币、骰子定格在动作瞬间），访客端不再实时生成，进入大厅无额外 GPU 开销。`lib/game-covers.js` 保存封面姿态，桌面鼠标悬停时挂载实时场景播放演示循环。每个游戏单独计版本（`lib/game-covers.js` 的 `COVER_VERSIONS`）；重新渲染用 `node script/render-game-covers.cjs coin=v3 ...` 生成新文件并更新映射，脚本不覆盖已有文件。
- `lib/game-motion.js`：有场景时播放 3D；场景 2.5 秒内未就绪、加载失败或不支持 WebGL 2 时退回 CSS 动画。
- 系统开启“减少动态效果”时仍播放同样的过程，时长约缩短一半，并取消镜头漂移和金币粒子，不再直接跳到结果。
- 结果只用于展示：金额、开奖号码与结算都在请求返回时由服务器确定，动画不影响结算。

## 验证

```sh
RSC_PLAYWRIGHT=/abs/node_modules/playwright RSC_CHROMIUM=/abs/chrome \
RSC_BROWSER_OUTPUT=/tmp/rsc-browser-artifacts RSC_BROWSER_SCRIPT=game-motion-browser.cjs \
bash test/run-browser-isolated.sh
```

`game-motion-browser.cjs` 分别以 WebGL 和隐藏 WebGL 2 的方式运行：画布在动画中变化、连续相同结果也会重新播放、终态与服务器结果一致；21点 发牌期间按钮锁定、停牌后翻开暗牌；刮卡可用鼠标刮开单格并全部刮开；减少动态效果、路由切换清理和手机布局；CSS 模式不下载 three.js。测试环境没有 GPU（SwiftShader），帧率远低于真实设备，因此等待时间较长。

更新 three.js 的方法见 `public/javascripts/README.md`。
