# 三刀全修 + 移除删除线路

## 删除线路（双端）
- **iOS**：去掉菜单/Alert/`confirmDeleteLine`/`doDeleteLine`
- **Android**：去掉确认对话框、`deleteCurrentLineAndJump`、源管理长按删线
- 源列表「删除直播源」仍保留（删的是 m3u 源，不是单条线路）

---

## 第 1 刀 — 正确性

### iOS
- 暂停不算卡顿：`isStalled` / 健康检测跳过 `.paused`
- `userPaused`：回前台 `resumeIfAppropriate`，中断恢复尊重用户暂停
- 自动换线在 `userPaused` 时不触发

### Android
- 换源 `loadChannels(false)`：**不灌旧融合缓存**
- 删线功能已移除（原 `resetTriedLines` 问题一并消失）
- 融合模式切换同样 `loadChannels(false)`

---

## 第 2 刀 — 体验 / 稳定

### iOS
- 融合首批只走返回值，取消 Notification 双投递
- 收藏分区：每台只出现一次，避免 List 重复 id
- 空格键走 `vm.pause/resume`（Now Playing 同步）
- 内存警告 observer 正确 remove
- 融合优化结果 `saveChannels` 落盘
- 亮度手势关闭（系统调节）

### Android
- 点画面关侧栏
- 去掉 `playCurrent` 300ms 自动关栏
- `shouldSkipChannelLine` 恒 false（不再按下标误伤）
- 「快速」文案改为顺序首可用源
- Adapter 去掉 OnKeyListener，OK 只走 Activity

---

## 第 3 刀 — 产品（部分）

| 项 | 状态 |
|----|------|
| 快速文案对齐实现 | ✅ Android |
| 缓存换源隔离 | ✅ Android useCache |
| 收藏不重复 | ✅ iOS |
| 大列表迁文件 | 未做（仍 SP/Defaults） |
| complete 真测速 | 未做 |
| 并行竞速 fast | 未做（改文案） |

---

## 版本
- iOS：**1.5.31 (65)**
- Android：**1.5.5 (9)** · 包名仍 `TVPlayer-安卓TV-v…`
