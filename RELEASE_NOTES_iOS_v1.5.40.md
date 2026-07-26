# TVPlayer iOS v1.5.40

## 小白条 / 底部黑边（真正按主流播放器做）

**你反馈的根因（上一版自己造的 bug）：**
- 旧代码用 `bottomPad = 34` 故意把画面缩短一截「等」小白条
- 所以：白条 auto-hide 后，底部黑边还在；回前台 forceFullBleed 才像「补齐」

**正确做法（Netflix / 系统横屏全屏同类）：**
1. `AVPlayerLayer` 一开始就 `frame = window 全屏`（含 Home Indicator 区域）
2. 小白条只浮在画面上，不参与布局、不占高度
3. 删掉 bottomPad / 缩短 videoH 逻辑
4. 主 window 选择优先 `AppDelegate.window`，不挂到侧栏 overlay
5. Hosting 约束钉 `view` 四边，不用 `safeAreaLayoutGuide`

> iOS 仍会在从底边上滑时短暂显示 Home Indicator，这是系统行为；正常播放应 auto-hide，且画面始终全屏。

## 版本
1.5.40 (74)
