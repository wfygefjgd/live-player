# TVPlayer iOS v1.5.13 Release Notes

## 🎯 重大改进：无需代理访问所有源

### 核心更新
- **GitHub Pages 镜像系统**：3个 GitHub raw 源已迁移到自动镜像，国内无代理也能访问
- **每日自动同步**：每天北京时间 6:00 自动更新镜像源，保持最新频道列表

### 修复的源
所有源现在均可在国内无代理访问：
1. ✅ **IPTV-ORG 全球项目** - GitHub Pages CDN（305+ 频道）
2. ✅ **CCTV+ 官方直播** - 央视官方源
3. ✅ **BurningC4 源** - 已迁移到 GitHub Pages 镜像
4. ✅ **zbefine 2026 源** - 已迁移到 GitHub Pages 镜像
5. ✅ **suxuang IPv6 源** - 已迁移到 GitHub Pages 镜像
6. ✅ **Angel TV** - Akamai 全球 CDN

## 🐛 Bug 修复

### 频道切换方向修复
- **修复滑动方向逻辑**：现在滑动方向符合列表视觉预期
  - 向下滑 = 下一个频道（第1→第2）
  - 向上滑 = 上一个频道（第2→第1）
- **解决跳转问题**：修复从第1个频道切换时跳回第100个的问题

## 📦 构建信息

- **版本号**: 1.5.13 (Build 47)
- **发布日期**: 2026-07-25
- **最低系统**: iOS 16.0+
- **支持设备**: iPhone, iPad

## 🔄 技术细节

### 自动镜像系统
- 使用 GitHub Actions 自动同步上游源
- 通过 GitHub Pages 提供 CDN 加速
- 完全无需手动维护

## 💡 使用说明

现在 App 的所有内置源都可以在国内无代理环境下正常访问，无需任何额外配置。

---

**完整变更日志**: https://github.com/wfygefjgd/live-player/compare/v1.5.12-ios...v1.5.13-ios
