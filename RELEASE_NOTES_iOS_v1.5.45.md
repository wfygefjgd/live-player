# TVPlayer iOS v1.5.45

## 霸道全屏：不给小白条让位
- **移除** 网络接入后重载画面（消除闪屏）
- 画面层锁定 **物理横屏尺寸**（nativeBounds），safeArea / Home Indicator 变化时**不缩小**
- 小白条只能浮在画面上，不能挤走画面
- 回前台只 rebind + 钉锁定尺寸，不再 hardRemount 风暴

## 版本
1.5.45 (79)
