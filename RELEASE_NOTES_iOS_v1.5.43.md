# TVPlayer iOS v1.5.43

## 修复 1.5.42 闪退
- 根因：`hardRemount` → `layoutIfNeeded` → `viewDidLayoutSubviews` → 再 `hardRemount` 递归爆栈
- 防重入 + 0.25s 节流
- `viewDidLayoutSubviews` 只调轻量 `forceFullBleed`，禁止 hardRemount
- 去掉启动时连打多次 hardRemount / refreshChromeAndVideo 风暴
- 不再改 `window.frame`（避免系统布局崩溃）

## 版本
1.5.43 (77)
