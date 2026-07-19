# Python TV Player - 电视直播软件

## 两个版本

| 版本 | 文件 | 说明 |
|------|------|------|
| 基础版 | `tv_player.py` | 使用tkinter，无需VLC |
| 增强版 | `tv_player_pro.py` | 使用PySide6+VLC，功能更全 |

## 直播源来源 (GitHub)

- [best-fan/iptv-sources](https://github.com/best-fan/iptv-sources) - 央视卫视
- [Supprise0901/TVBox_live](https://github.com/Supprise0901/TVBox_live) - 直播源检索
- [vbskycn/iptv](https://github.com/vbskycn/iptv) - IPv4/IPv6源
- [fanmingming/live](https://github.com/fanmingming/live) - IPv6直播源
- [iptv-org/iptv](https://github.com/iptv-org/iptv) - 全球直播源

## 快速开始

### 增强版 (推荐)

需要安装:
- Python 3.8+
- VLC Media Player: https://www.videolan.org/

```bash
pip install -r requirements_pro.txt
python tv_player_pro.py
```

或双击 `启动电视直播.bat`

### 基础版

```bash
pip install -r requirements.txt
python tv_player.py
```

## 功能

### 增强版功能
- VLC内置播放器，直接观看
- 频道收藏功能
- 分组筛选 (央视/卫视/其他)
- 搜索频道
- 多直播源切换
- GitHub镜像加速
- 播放地址复制
- 音量调节 (左右方向键)
- 空格暂停/播放
- F5刷新

### 基础版功能
- 显示播放地址 (需外部播放器)
- 搜索和分组
- 多源切换

## 快捷键 (增强版)

| 按键 | 功能 |
|------|------|
| 左/右 | 调节音量 |
| 空格 | 暂停/播放 |
| F5 | 刷新频道 |
| F | 聚焦搜索框 |

## 注意事项

1. 需要安装VLC才能使用增强版
2. 直播源可能随时失效，点击"刷新"获取最新
3. 部分源可能需要特定网络环境
4. 仅供学习研究使用
