# TVPlayer iOS v1.5.50

## 按 Flutter 沉浸式全屏映射（方案 B 干净版）

对应你给的 Flutter 要求：

| Flutter | iOS |
|---------|-----|
| 去掉播放器外 SafeArea | 视频 `.ignoresSafeArea(.all)`，根约束贴 `view` 四边 |
| `extendBody` / `extendBodyBehindAppBar` | `edgesForExtendedLayout = .all` |
| `SystemUiMode.immersiveSticky` | `prefersHomeIndicatorAutoHidden` + `defersSystemGestures` + 隐藏状态栏 |
| 视频贴底铺满 | `PlayerSurfaceView` 铺满物理布局 |
| 控制栏 `padding.bottom` | 仅 OSD/指示器/数字键用 `safeAreaInsets.bottom` 抬高 |

无 hardRemount / 负 safeArea / 独立 video window 等旧 hack。

## 版本
1.5.50 (84)
