# 包 ① + ② 变更说明

## 方案 A：去掉悬浮角标 + 锁定（iOS / Android 同步）

### iOS
- 删除 `FloatingButtons.swift`
- 移除 `locked` / `showFloatOverlay` / `toggleLock` / float 定时隐藏
- 长按：**开关**侧栏；双击：开关侧栏；手势换台/换线/音量保留

### Android
- 布局去掉 `btn_toggle_panel` / `btn_lock`
- 侧栏顶部：**源管理 / 融合模式**
- 长按：开关侧栏；**双击**：源管理；长按侧栏顶栏：删线
- 底部手势提示 5 秒后消失

## P0 正确性

### iOS
- 融合 `session` + 通知 `userInfo`，旧后台结果不再盖新列表
- `hideLine` **同步**写入，删线立刻生效
- 播放时 `isIdleTimerDisabled = true`（常亮）
- AppDelegate **不再**把 `additionalSafeAreaInsets` 清零（与负向 inset 统一）

### Android
- 删线：**本地过滤**，禁止主线程 `httpGet`
- 融合按 **channel.key** 合并线路
- **用户源 + active** 参与融合；内置源补齐
- 禁止「首 URL 丢整台」
- smart 软合并：已有列表/起播中 **不重播**
- `loadGeneration` 丢弃过期融合结果
- HTTP `disconnect` + UTF-8

## 版本
- iOS：**1.5.29 (63)**
