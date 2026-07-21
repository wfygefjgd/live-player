# TV Player - 电视直播播放器

Python 桌面版对齐 Android 原生逻辑（同名折叠、多线路、自动换线、源管理）。

## 功能（与 Android 原生一致）

- 默认源：`best-fan cn_all_status.m3u8`（含 GitHub 镜像兜底）
- 同名频道折叠为一个列表项，内部保留多条线路
- 左右方向键：切换当前频道线路
- 上下方向键：切换频道
- 空格 / 单击画面：暂停/播放
- 左上角 ▶/◀：隐藏/显示频道面板
- 右键左上角 / 按 `S`：源管理（添加/删除自定义 m3u、切换默认源）
- 左下角 🔓/🔒：锁定/解锁
- 右键左下角 / `Delete`：删除当前线路并自动跳下一线路
- 启动默认隐藏左侧面板；播放稳定后悬浮按钮自动隐藏
- 当前线路约 7 秒未接通或进程异常时，自动切到同频道下一线路
- 搜索、收藏、隐藏频道、复制线路地址
- 缓存节目单（启动可先读缓存再后台刷新）

## 快捷键

| 按键 | 功能 |
|------|------|
| ↑ / ↓ | 上/下一频道 |
| ← / → | 上一/下一线路 |
| Ctrl+← / Ctrl+→ | 音量 -/+ |
| 空格 | 暂停/播放 |
| F5 | 刷新频道 |
| Esc | 显示/隐藏面板 |
| S | 源管理 |
| L | 锁定/解锁 |
| Delete | 删除当前线路 |

## 使用方法

### 直接运行 EXE
- 双击 `TVPlayer_TK.exe`（需自行重新打包以包含本次更新）

### 运行 Python 脚本
```bash
pip install requests
python tv_player_tk.py
```
或双击 `启动tkinter版.bat`

### 依赖
- Python 3.8+
- mpv 播放器（推荐放到 `%USERPROFILE%\mpv\mpv.exe`）
- requests

## 文件说明

| 文件 | 说明 |
|------|------|
| tv_player_tk.py | 桌面推荐版（tkinter + mpv，对齐 Android） |
| tv_player_mpv.py | PySide6 + mpv 旧版 |
| tv_player_pro.py | PySide6 + VLC 旧版 |
| tv_player.py | tkinter 基础旧版 |
| android-native/ | 原生 Android（Java + ExoPlayer） |
| android_main.py | Kivy Android 版 |

## 配置目录

`%USERPROFILE%\.tv_player\`

- `channels_cache.json` 频道缓存
- `source_urls.json` / `selected_source.json` 源列表与当前源
- `hidden_lines.json` 已删除线路
- `favorites.json` / `hidden.json` 收藏与隐藏频道

## License

MIT
