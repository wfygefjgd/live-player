# TVPlayer iOS v1.5.42

## 针对 iPhone Air：复现「回前台才正常」的路径

你反馈：竖→横冲击无效；**只有退后台再进**画面才补齐。

### 做法
- **废弃** 竖屏启动冲击
- 新增 `hardRemount`：卸 host → 按物理横屏尺寸重挂 → `player = nil` 再绑回（与回前台 rebind 同构）
- 触发点：`didBecomeActive` / 出画 `onPlayerReady` / 旋转结束 `viewWillTransition` / `geometryDidChange` / 尺寸跳变
- 固定横屏（Info.plist 去掉 Portrait）

请在 iPhone Air 上冷启动验证：出画后应直接全屏，无需再切后台。

## 版本
1.5.42 (76)
