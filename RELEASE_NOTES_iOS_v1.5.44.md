# TVPlayer iOS v1.5.44

## 网络接入后重载画面（等同退后台再进）
- 网络从无到有：`reloadSurfaceLikeForeground`（与回前台同一套 forceFullBleed / hardRemount）
- WiFi / 蜂窝类型就绪：同样钉一次画面（覆盖「允许本地网络」后才通的情况）
- 启动约 1.2s 后若已联网，再自动重载一次（等权限弹窗与横屏落稳）
- 回前台恢复改为共用 `recoverPlaybackAfterForeground`

针对 iPhone Air：小白条仍在时，联网后应自动把画面铺满。

## 版本
1.5.44 (78)
