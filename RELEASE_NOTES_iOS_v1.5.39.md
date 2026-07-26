# TVPlayer iOS v1.5.39

## 小白条（Home Indicator）再修
- 新增 `FullScreenRootController` 作为真正 window root：Home Indicator / 手势 / 状态栏策略由纯 UIKit 容器持有，不再依赖 `UIHostingController` 内部子节点
- 增加 `SceneDelegate` + `UIApplicationSceneManifest`，窗口绑定正确 `UIWindowScene`
- 侧栏 overlay window 加 root VC 且永不抢 keyWindow
- `UIViewControllerBasedStatusBarAppearance = true`，与 VC 级隐藏策略一致
- 定期 `setNeedsUpdateOfHomeIndicatorAutoHidden`；画面层底部外扩黑底盖住条区域

> 说明：iOS 不允许永久删除 Home Indicator，只能 auto-hide；触摸底部边缘时系统仍可能短暂显示。

## 版本
1.5.39 (73)
