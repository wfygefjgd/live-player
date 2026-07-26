# TVPlayer iOS v1.5.48

## 按你的判断：下沉的是「容器」，不是画面

### 当前层级（改前问题）
- 画面 host：主 window 的 subview（index 0）
- **容器** `rootViewController.view`：被系统 **safeArea / 小白条** 往上挤 → 看起来像画面缺底边
- 所以不是画面层不够低，是**容器没沉到底**

### 本版
1. `SinkContainerView`：`safeAreaInsets` 强制 **0**（容器不给小白条留位）
2. 布局时把容器 **frame 钉死 = window.bounds**（整窗下沉铺满）
3. 正确一次抵消 system safeArea（不循环叠加）
4. Hosting 子容器跟着父容器 bounds 铺满

## 版本
1.5.48 (82)
