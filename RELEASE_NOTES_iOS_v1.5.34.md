# TVPlayer iOS v1.5.34

## 画面
- **强制拉伸** `resize`：上下左右拉满整屏（允许变形，无比例裁切黑边）
- 外扩 24pt + 负向 safeArea，继续压小白条

## 换线（网速逻辑）
- **立刻换**：网络未连接 / 几乎无速度（&lt;5KB/s）约 1.2s
- **暂缓**：采样 ≥50KB/s 时不因 waiting 误切
- **再换**：持续 &lt;50KB/s 约 2s 后换线
- 采样：AVPlayer accessLog `observedBitrate` / 字节差分，约 0.5s 一轮

## 版本
1.5.34 (68)
