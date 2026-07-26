# TVPlayer iOS v1.5.28 + Android 融合模式

## iOS v1.5.28 — 小白条 / 有声无画 强力修复

- 画面层按 **物理屏幕 nativeBounds** 钉死全屏，可溢出 window 盖住 Home Indicator
- `additionalSafeAreaInsets` 负向抵消系统 inset，布局延伸进小白条区域
- ContentView 底色改为 **透明**，避免挡住 window 底层 `AVPlayerLayer`（有声无画根因）
- 出画 / 回前台 / 定时 keep-alive 强制 `rebindPlayer` + `forceFullBleed`
- 起播就绪后立刻重绑 layer 与全屏校正

**版本**: 1.5.28 (Build 62)

## Android — 融合模式（与 iOS 对齐）

源管理弹窗新增 **融合模式**：

| 模式 | 行为 |
|------|------|
| 关闭 | 仅当前选中源 |
| 快速 | 多镜像竞速，取最快 |
| 平衡 | 融合前 3 个内置源 |
| 完整 | 融合全部内置源 |
| 智能（默认） | 首源先出画，后台全量合并 |

设置写入 `SharedPreferences`，下次启动恢复。
