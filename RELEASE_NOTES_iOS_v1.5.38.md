# TVPlayer iOS v1.5.38

## 小白条 / 黑边
- 去掉 SwiftUI `WindowGroup` + `AppDelegate` 双入口冲突，只保留 `@main AppDelegate` 真窗口
- 窗口绑定 `UIWindowScene`，避免 bounds 与物理屏脱节
- 画面层按**物理屏**铺满（可盖住 Home Indicator），禁止 rebind 时居中偏移导致画面被顶起
- 禁止负向 `additionalSafeAreaInsets` 震荡

## 退出后台再进黑屏
- 回前台：`resumeIfAppropriate` 在 item 丢失时重拉当前线
- `onAppBecameActive`：未播放则 resume；约 0.9s 仍未 ready 则重播当前线并 forceFullBleed

## 默认频道 CCTV1
- 无上次记录时，无论源语言/分组名，默认第一台为 CCTV1（中央一台/综合）
- 侧栏浏览序与央视组内排序：CCTV1 置顶

## 版本
1.5.38 (72)
