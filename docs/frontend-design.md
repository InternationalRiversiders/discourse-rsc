# RSC 前端视觉优化

2026-09-20。本轮保留原生业务流程，调整钱包、行情、持仓、赛事预测、排行榜与管理页的视觉层次。截图均为隔离论坛的合成测试数据，未部署线上。

- 钱包：余额卡片、转账与红包区块、统一表单与状态样式。
- 行情：保留分类、搜索、排序、分页和走势图；手机页头更紧凑，优先显示行情列表。
- 持仓：方向与杠杆独立标识，数量、保证金、浮动盈亏和预计爆仓价分项展示。
- 赛事：比赛双方、时间和状态分层展示；赔率选项强化选中状态。
- 排行榜：增加名次列和前三名标记；管理页统一标题与间距。
- 余额格式化只处理字符串整数部分的千位分隔，不转换为浮点数或截断小数。

| 页面 | 桌面 | 手机 | 深色 |
| --- | --- | --- | --- |
| 钱包 | [查看](screenshots/design/wallet-desktop.png) | [查看](screenshots/design/wallet-mobile.png) | [查看](screenshots/design/wallet-dark.png) |
| 股市 | [查看](screenshots/design/market-desktop.png) | [查看](screenshots/design/market-mobile.png) | [查看](screenshots/design/market-dark.png) |
| 赛事预测 | [查看](screenshots/design/sports-desktop.png) | [查看](screenshots/design/sports-mobile.png) | [查看](screenshots/design/sports-dark.png) |
| 排行榜 | [查看](screenshots/design/leaderboard-desktop.png) | [查看](screenshots/design/leaderboard-mobile.png) | [查看](screenshots/design/leaderboard-dark.png) |

已通过真实浏览器的转账、红包退款、行情搜索/分类/排序/分页、下单成交、持仓、预测、打赏、管理及通知流程；四个主页面在 320、390、768、1440 像素宽度均无整页水平溢出，实际 Discourse 深色方案、代表性辅助文字对比度与 JavaScript 运行检查通过。

社区插件的同轮效果与视觉测试脚本在相邻 `discourse-community-test` 仓库。本次验收不覆盖所有第三方主题组合，线上安装仍需按部署文档完成验收。
