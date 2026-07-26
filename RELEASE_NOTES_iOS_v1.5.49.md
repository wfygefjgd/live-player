# TVPlayer iOS v1.5.49

## 清掉小白条 hack + 方案 A：让路

### 删除
- 物理全屏 / bottomPad / hardRemount / SinkContainer / 负 safeArea / 独立 video window
- OrientationBootstrap 竖横冲击
- 网络接入后重载画面
- 强制 `prefersHomeIndicatorAutoHidden`、Info.plist 相关项
- layout 风暴与容器下沉 hack

### 方案 A（本版）
- 根容器用 **safeAreaLayoutGuide** 约束
- 画面 `PlayerSurfaceView` 只在安全区内铺满
- 系统 Home Indicator 正常占底边，**不与系统抢像素**
- 横屏播放 + 黑底；回前台只 rebind 播放器

可接受底边有系统条占位就保持；要物理全屏再做方案 B。

## 版本
1.5.49 (83)
