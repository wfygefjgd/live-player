# TVPlayer iOS v1.5.51

## Edge-to-Edge 标准全屏（Swift）

按你的约束实现：

1. **播放器不使用 Safe Area 缩进** — 视频 `.ignoresSafeArea()`，UIKit 约束钉 `view` 四边（不用 `safeAreaLayoutGuide`）
2. **画面贴物理边** — Home Indicator 半透明浮在视频上，不把画面挤上去
3. **隐藏 / 自动淡化系统栏**
   - UIKit: `prefersHomeIndicatorAutoHidden`、`prefersStatusBarHidden`、`preferredScreenEdgesDeferringSystemGestures`
   - SwiftUI: `.statusBarHidden(true)`、`.persistentSystemOverlays(.hidden)`、`.defersSystemGestures(on: .all)`
4. **仅浮动 OSD** 用 `safeAreaInsets` 抬高，视频本身不让路

## 版本
1.5.51 (85)
