# TVPlayer iOS v1.5.20 Release Notes

## 🐛 Bug 修复

### 修复源切换失败问题
- **核心问题**：用户切换源时频道数始终为 58 个，无法加载新源的频道
  - 原因：`reloadActiveSource()` 调用 `loadChannels()` 时未指定 `preferActiveOnly: true`
  - 在融合模式关闭时，系统会回退到 `buildCandidates()`，导致使用多个源而非当前选中源
  - 修复方案：强制使用 `preferActiveOnly: true`，确保只加载当前选中的源

### 技术细节
- **受影响函数**：`PlayerViewModel.reloadActiveSource()`
  - 修改前：`loadChannels(force: true, silent: false)`
  - 修改后：`loadChannels(force: true, silent: false, preferActiveOnly: true)`
- **效果**：切换源时，频道数会根据所选源的实际频道数正确变化

## 📦 构建信息

- **版本号**: 1.5.20 (Build 54)
- **构建日期**: 2026-07-25
- **最低系统**: iOS 16.0+
- **支持设备**: iPhone, iPad

## 🔄 变更摘要

此版本修复了源切换功能失效的严重问题，现在用户可以正常切换不同的直播源。

---

**完整变更日志**: https://github.com/wfygefjgd/live-player/compare/v1.5.19-ios...v1.5.20-ios
