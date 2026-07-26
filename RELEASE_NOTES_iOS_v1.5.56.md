# TVPlayer iOS v1.5.56

## 小白条 / 四周黑边（最小稳妥修复）

### 根因
1. **小白条挤占**：系统 bottom safeArea 仍参与布局；`additionalSafeAreaInsets = .zero` 无法抵消
2. **四周黑边**：`forcePhysicalFullScreen` 每 layout 强改 `window.frame`，scene 未横时对调宽高 → 中间小框 + 四周黑底，再叠 `resizeAspect` 比例黑边

### 本版改动
1. `SinkContainerView`：`safeAreaInsets` 强制 **0**，容器不给 Home Indicator 让高度
2. 播放子视图 Auto Layout **钉 view 四边**（不用 safeAreaLayoutGuide）
3. **删除** layout 周期改 `window.frame` / 手写物理尺寸对调
4. `sizeThatFits` 跟随父 proposal，不再用 `UIScreen` 锁死尺寸
5. 侧栏 `PanelRootViewController` 补全 `prefersHomeIndicatorAutoHidden`
6. 视频保持 `resizeAspect`（完整画面，只允许两边比例黑边）

### 版本
1.5.56 (90)
