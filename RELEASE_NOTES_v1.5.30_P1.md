# 包 ③ 播放体验 / P1（iOS 1.5.30 + Android）

## 本批做了什么

### iOS
| 项 | 说明 |
|----|------|
| 缓存优先 Bundle | 用户融合缓存先于内置 JSON |
| Now Playing | 锁屏显示频道名 + 直播标记 |
| 中断恢复 | 来电结束后自动 resume |
| 静音误判 | 8s + 三轮确认 + asset 音轨兜底 |
| 源列表 id | 用 url 而非 offset |
| Channel.== | 含 urls，列表能刷新线路 |
| RootView | 不再每次重建 ContentView |
| 亮度手势 | 左侧滑动（对齐 Android） |
| 画面比例 | `resizeAspectFill` 不再拉伸 |

### Android
| 项 | 说明 |
|----|------|
| 记忆频道 | save/load last channel + source |
| 假 READY | 仅 `isPlaying` 才写成功信誉 |
| 无声误判 | 8s + 二次确认；检测 track group 存在 |
| 缓存恢复位置 | restoreLastChannelPosition |

## 仍建议后续（未做）
- 大列表迁文件存储
- Android 收藏/搜索 UI
- God Object 拆分
- 镜像前缀对齐 iOS
- complete 模式真实测速
