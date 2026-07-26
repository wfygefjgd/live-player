# TVPlayer iOS v1.5.46

## 新方案：画面与 UI 分两层 Window
你提的「不要和小白条同一层」——系统 Home Indicator 无法被 App 图层压过，但可以把**画面放到独立底层 Window**：

1. **Video Window**：`windowLevel = normal - 1`，铺满物理横屏，永不 makeKey  
2. **主 UI Window**：透明、`normal` level、负责手势/侧栏/OSD  
3. 画面与主窗 safeArea **完全脱钩**，小白条挤主窗布局时**挤不到 video 层**

小白条仍可能浮在最上面（系统层），但不应再把画面顶出黑边。

## 版本
1.5.46 (80)
