# TVPlayer iOS v1.5.11 Release Notes

## 🐛 Bug 修复

### 构建修复
- **修复 iOS 构建失败问题**：修正了 `FusionMode` 枚举默认值错误
  - 将默认值从不存在的 `.off` 改为 `.fast`
  - 确保与枚举定义一致（fast/balanced/complete/smart）

## 📦 构建信息

- **版本号**: 1.5.11 (Build 45)
- **编译日期**: 2026-07-25
- **最低系统**: iOS 16.0+
- **支持设备**: iPhone, iPad

## 🔄 变更摘要

此版本主要修复了 GitHub Actions 构建失败的问题，确保 CI/CD 流程正常运行。

---

**完整变更日志**: https://github.com/wfygefjgd/live-player/compare/v1.5.10-ios...v1.5.11-ios
