# 游戏 3D 动画

2026-11-07。老虎机、欧式轮盘、抛硬币、骰子大小改为 WebGL 实时渲染；二十一点、刮刮乐保留 DOM，增强为 3D 发牌翻牌和中奖高亮。

## 结构

- `lib/game-3d-scenes.js`：四个场景（不直接 import three，由调用方注入）。所有终态只由回合 `id` 与服务器 `state` 推导，动画结束画面与之后查看历史记录的静态画面一致。
- `lib/game-3d.js`：检测 WebGL 2，运行时从 `/plugins/discourse-rsc/javascripts/rsc-three-0.186.1.js` 动态加载 three.js（tree-shaken，约 136 KB gzip），大厅空闲时预取。
- `lib/game-motion.js`：有场景时播放 3D；场景 2.5 秒内未就绪、加载失败或浏览器不支持 WebGL 2 时，退回原 CSS 动画。系统开启“减少动态效果”时直接显示结果。
- 结果只用于展示：金额、开奖号码与结算都在请求返回时由服务器确定，动画不影响结算。

渲染按需进行，只在动画期间和尺寸变化时绘制；离开游戏会释放 WebGL 上下文。

## 验证

```sh
RSC_PLAYWRIGHT=/abs/node_modules/playwright RSC_CHROMIUM=/abs/chrome \
RSC_BROWSER_OUTPUT=/tmp/rsc-browser-artifacts RSC_BROWSER_SCRIPT=game-motion-browser.cjs \
bash test/run-browser-isolated.sh
```

`game-motion-browser.cjs` 分别以 WebGL 和隐藏 WebGL 2 的方式运行：检查画布在动画中变化、连续相同结果也会重新播放、终态标签与服务器结果一致、减少动态效果、路由切换清理和手机布局；CSS 模式不下载 three.js。

更新 three.js 的方法见 `public/javascripts/README.md`。
