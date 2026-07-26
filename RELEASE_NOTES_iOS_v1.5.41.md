# TVPlayer iOS v1.5.41

## 试验：启动竖屏 → 极速切横屏（冲击布局）

按用户方案试做：

1. 冷启动先锁 **竖屏**（黑屏，用户几乎无感）
2. 约 **0.28 秒**后切到 **横屏** 并锁死
3. 用系统旋转重建 window / safe area / Home Indicator，再 forceFullBleed 钉画面

实现：`OrientationBootstrap` + Info.plist 增加 Portrait 支持；运行时仍以横屏为主。

若仍有底部黑边，请反馈机型与 iOS 版本。

## 版本
1.5.41 (75)
