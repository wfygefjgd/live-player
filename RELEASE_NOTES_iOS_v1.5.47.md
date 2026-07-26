# TVPlayer iOS v1.5.47

## 按用户方案：容器透明 + 画面在最底

1. **去掉** 独立底层 Video Window（上版方案作废）
2. **window / root / SwiftUI 容器全部透明** —— 底下不再垫黑底挡画面
3. 画面 host 插在主 window **index 0（最底层）**，不低于容器
4. host / AVPlayerLayer 铺满**物理全屏**，不读 safeArea，不给小白条让位
5. 顺带清掉主界面子树里近黑背景，避免“透明容器下还有一层黑”

## 版本
1.5.47 (81)
