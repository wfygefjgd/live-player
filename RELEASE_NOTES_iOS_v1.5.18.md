# TVPlayer iOS v1.5.18 Release Notes

## 🔥 暴力修复 Home Indicator

### 多重暴力手段组合拳
本版本采用了所有可能的方法来彻底隐藏 iPhone 小白条：

1. **超大负边距**：`additionalSafeAreaInsets` 四周都设置 -50pt 超大负值
2. **强制扩展 Frame**：view.frame 向四周扩展 50pt，超出屏幕范围
3. **修改 Bounds**：直接修改 view.bounds 和 center，强制覆盖
4. **黑色遮罩层**：在底部添加黑色 UIView 遮罩，物理覆盖 Home Indicator 区域
5. **Info.plist 配置**：添加 `UIPreferredHomeIndicatorAutoHidden` 和 `UIRequiresFullScreen`
6. **高频定时器**：从 0.5 秒改为 0.1 秒，更频繁地强制隐藏
7. **多次延迟调用**：viewDidAppear 中延迟 10 次调用强制隐藏
8. **私有 API 尝试**：尝试调用私有方法 `setHomeIndicatorAutoHidden:`

### 默认源更换
- **更换为 IPTV-ORG 中国源**：`https://ghfast.top/raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u`

## 📦 构建信息

- **版本号**: 1.5.18 (Build 52)
- **构建日期**: 2026-07-25
- **最低系统**: iOS 16.0+
- **支持设备**: iPhone, iPad

## 🔄 变更摘要

此版本使用了所有可能的暴力手段来彻底解决 Home Indicator 显示问题，包括负边距、扩展 frame、黑色遮罩层、高频定时器等多重组合拳。

---

**完整变更日志**: https://github.com/wfygefjgd/live-player/compare/v1.5.17-ios...v1.5.18-ios
