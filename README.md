# TV Player - 电视直播播放器

Python + tkinter + mpv 实现的电视直播软件，支持GitHub IPTV源。

## 功能

- 多源自动加载（best-fan、TVBox、vbskycn、fanmingming）
- 搜索、分组筛选
- 收藏频道
- 右键菜单（收藏/隐藏/复制地址）
- 批量隐藏频道
- 恢复隐藏频道
- 播放/暂停、音量调节
- 面板隐藏/显示
- 缓存节目单（启动不联网）

## 使用方法

### 直接运行EXE
- 双击 `TVPlayer_TK.exe`

### 运行Python脚本
```bash
pip install requests
python tv_player_tk.py
```

### 依赖
- Python 3.8+
- mpv播放器（放在 `C:\Users\你的用户名\mpv\mpv.exe`）
- requests库

## 文件说明

| 文件 | 说明 |
|------|------|
| tv_player_tk.py | tkinter版本（推荐，12MB） |
| tv_player_mpv.py | PySide6+mpv版本（45MB） |
| tv_player_pro.py | PySide6+VLC版本 |
| tv_player.py | tkinter基础版 |
| channel_manager.py | 频道管理模块 |

## 截图

暗色主题，左侧频道列表，右侧视频播放。

## License

MIT
