# TVPlayer iOS v1.5.57

## 针对「1 中间小框四周黑 + 4 小白条顶起」

### 根因
画面仍在 SwiftUI / UIHostingController 布局树里，被安全区缩成中间卡片；小白条再顶高度 → 四周黑边 + 底边上移。

### 本版
1. **PlayerSurfaceView 钉在 root VC 底层四边**（脱离 SwiftUI 尺寸）
2. Hosting / ContentView **全透明**，只叠手势与 OSD
3. 视频不读 safe area；Home Indicator 只能浮在画面上
4. 保持 `resizeAspect`（完整画面，只允许两边比例黑边）

### 版本
1.5.57 (91)
