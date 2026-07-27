# IPTV 源镜像

自动同步 + 本地严格筛选后的 IPTV 源镜像，解决国内无代理无法访问 GitHub raw 的问题。

## 默认推荐源（严格筛选）

| 文件 | 说明 |
|------|------|
| [validated-channels.m3u](validated-channels.m3u) | 默认播放列表（App 默认源） |
| [validated-channels.json](validated-channels.json) | 同内容 JSON（Bundle / 快速启动） |

### 镜像访问（国内优先）

```
# jsDelivr CDN（推荐默认）
https://cdn.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u
https://fastly.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u

# GitHub Pages
https://wfygefjgd.github.io/live-player/iptv-mirrors/validated-channels.m3u
https://wfygefjgd.github.io/live-player/iptv-mirrors/validated-channels.json

# raw（需代理或走 gh-proxy）
https://raw.githubusercontent.com/wfygefjgd/live-player/main/iptv-mirrors/validated-channels.m3u
https://gh-proxy.com/https://raw.githubusercontent.com/wfygefjgd/live-player/main/iptv-mirrors/validated-channels.m3u
```

## 其它镜像

| 源名称 | 镜像文件 |
|--------|---------|
| BurningC4 Chinese-IPTV | [burningc4-chinese-iptv.m3u](burningc4-chinese-iptv.m3u) |
| zbefine IPTV | [zbefine-iptv.m3u](zbefine-iptv.m3u) |
| suxuang myIPTV | [suxuang-myiptv.m3u](suxuang-myiptv.m3u) |

## 更新

- 第三方源：每天自动同步（北京时间 6:00）
- 精选默认源：本地 multi-pass + 严格质量筛选后手动/脚本推送
