# TVPlayer iOS v1.5.26 Release Notes

## 🎯 侧边栏 Window 级浮层方案

### 侧边栏提升到 Window 层
- **侧边栏改为 Window 级浮层**：完全脱离 SwiftUI 视图层级限制
  - 创建 WindowPanelSurface 类，直接挂载到 UIWindow 上
  - 与画面层 WindowVideoSurface 同样的底层架构
  - 完全覆盖小白条区域，不受安全区域约束
  - 使用 UIView 动画实现流畅的滑入滑出效果

### 技术实现细节
- **WindowPanelSurface**: 单例管理侧边栏显示
  - 遮罩层 (maskView): 半透明黑色背景，点击关闭
  - 容器层 (containerView): 320px 宽侧边栏，带阴影效果
  - 动画: Spring 动画 (duration: 0.35, damping: 0.86)
  - 层级: 直接添加到 keyWindow，确保在最顶层

### 解决问题
- ✅ 侧边栏完全覆盖小白条区域
- ✅ 不受 SwiftUI 视图层级限制
- ✅ 与画面层采用相同的底层架构
- ✅ 真正的全屏浮层显示

## 📦 构建信息

- **版本号**: 1.5.26 (Build 60)
- **构建日期**: 2026-07-25
- **最低系统**: iOS 16.0+
- **支持设备**: iPhone, iPad

## 🔄 变更摘要

此版本将侧边栏提升到 Window 级浮层，与画面层采用相同的底层架构，完全脱离 SwiftUI 视图层级限制，真正覆盖小白条区域。

---

**完整变更日志**: https://github.com/wfygefjgd/live-player/compare/v1.5.25-ios...v1.5.26-ios
