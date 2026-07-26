# TVPlayer iOS v1.5.37

## 小白条修复
- 修复负向 safeArea 抵消公式：先还原系统 inset 再取负，消除 0 / -21pt 之间的布局震荡（画面被小白条反复上挤的根因）
- `.persistentSystemOverlays(.hidden)` / `.defersSystemGestures` / `.statusBarHidden` 上移到 WindowGroup 最外层，真正的 rootViewController 生效，小白条自动隐藏

## 镜像与源
- 新增 MirrorResolver：GitHub 系地址（Pages / raw）拉取时自动展开 jsDelivr、gh-proxy、raw 多路候选并发竞速，国内无代理可直连
- M3U 加载、融合模式、已筛选 JSON 三条链路全部接入镜像竞速
- 预置源更新：新增 Guovin 自动筛选源（默认）、vbskycn 双栈源、fanmingming IPv6 源（均已实测可达）；保留 BurningC4 / zbefine / suxuang 镜像

## 版本
1.5.37 (71)
