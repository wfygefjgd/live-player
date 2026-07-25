# TVPlayer 优化建议

## 1. tv_player_desktop.py 优化

### 问题 1: 代码不完整
**位置**: 第 1602 行
**问题**: 代码在 `if __name__ == "__main__":` 后突然结束
**建议**: 检查是否有缓存的完整版本

### 问题 2: PlayerEngine IPC 性能优化
**位置**: `PlayerEngine._ipc_call_windows()` 和 `get_playback_state()`
**问题**: 每次查询属性都重新建立连接
**优化方案**:
```python
# 建议添加连接池或保持连接
class PlayerEngine:
    def __init__(self, mpv_path: Optional[str]):
        # ... 现有代码 ...
        self._ipc_socket = None
        self._ipc_lock = threading.Lock()
    
    def _get_properties_batch(self, props: List[str]) -> dict:
        """批量获取属性，减少 IPC 调用次数"""
        with self._ipc_lock:
            results = {}
            for prop in props:
                val = self._get_property(prop)
                if val is not None:
                    results[prop] = val
            return results
```

### 问题 3: 硬编码的频道规则
**位置**: `should_skip_channel_line()`
**问题**: 规则硬编码，无法灵活配置
**优化方案**:
```python
# 建议使用配置文件
# ~/.tvplayer_android_port/channel_rules.json
{
  "skip_rules": [
    {"key": "cctv10", "skip_indices": [0]},
    {"key": "cctv14", "skip_indices": [0]},
    {"key": "cctv13", "skip_indices": [0, 1, 2]},
    {"key": "北京", "skip_indices": [0]},
    {"key": "湖南", "skip_indices": [0, 1]}
  ]
}

class StorageHelper:
    def load_channel_rules(self) -> dict:
        """从配置文件加载频道规则"""
        return self._read_json("channel_rules.json", {"skip_rules": []})
```

### 问题 4: 重复的卡顿检测
**位置**: `is_stalled()` 和 `_start_watch()`
**建议**: 统一卡顿检测逻辑，避免重复检查

### 问题 5: 错误提示可以更友好
**位置**: `play_current()` - 第 1422 行
**建议**:
```python
# 当前
self.status.config(text=f"请安装 mpv 到 {Path.home() / 'mpv' / 'mpv.exe'}")

# 建议改为
self.status.config(text="未找到 mpv - 点击获取安装指南")
# 并添加点击事件打开安装链接
```

## 2. tv_player_mpv.py 优化

### 问题 1: 音量初始化冗余
**位置**: `MainWindow.__init__()` - 第 583-584 行
**问题**:
```python
self.video.set_volume(self._volume)
self._volume = 100  # 这行多余
```
**修复**: 删除第 584 行

### 问题 2: MPV 启动失败处理不完善
**位置**: `MPVWidget.play_url()`
**建议**:
```python
def play_url(self, url):
    # ... 现有代码 ...
    self._process.errorOccurred.connect(self._on_error)  # 添加错误处理
    self._process.start(cmd[0], cmd[1:])
    
    # 添加启动超时检测
    QTimer.singleShot(3000, self._check_start_timeout)

def _on_error(self, error):
    """处理 mpv 启动错误"""
    self._is_playing = False
    if error == QProcess.FailedToStart:
        self.show_msg("mpv 启动失败 - 请检查安装")
    else:
        self.show_msg(f"播放错误: {error}")
```

### 问题 3: 测速性能优化
**位置**: `SpeedTester.run()`
**建议**:
```python
# 当前批量大小为 3，可以根据 CPU 核心数动态调整
import multiprocessing
batch_size = max(3, multiprocessing.cpu_count() - 1)

# 添加测速进度回调
class SpeedTester(threading.Thread):
    def __init__(self, channels, progress_callback=None):
        super().__init__()
        self.progress_callback = progress_callback
        # ...
    
    def run(self):
        total = len(self.channels)
        for i in range(0, total, batch_size):
            # ...
            if self.progress_callback:
                self.progress_callback(i, total)
```

### 问题 4: 内存优化
**位置**: `SourceLoader.fetch_one()`
**问题**: 大文件加载时一次性读入内存
**建议**:
```python
# 添加文件大小限制
MAX_M3U_SIZE = 10 * 1024 * 1024  # 10MB

def fetch_one(self, src):
    # ...
    resp = requests.get(url, headers=HEADERS, timeout=TIMEOUT, stream=True)
    resp.raise_for_status()
    
    # 检查文件大小
    content_length = resp.headers.get('content-length')
    if content_length and int(content_length) > MAX_M3U_SIZE:
        return []  # 跳过过大的文件
    
    # ...
```

### 问题 5: UI 响应性
**位置**: `_on_select()` - 第 701 行
**建议**: 已经使用了 `_switch_timer`，很好！但可以添加取消机制：
```python
def _on_select(self, row):
    if self._select_mode or row < 0 or row >= len(self.filtered_channels):
        return
    
    # 如果正在切换，取消之前的定时器
    if self._switch_timer.isActive():
        self._switch_timer.stop()
    
    url = self.filtered_channels[row].url
    self._pending_url = url
    self.video.stop_mpv()
    self._switch_timer.start()
```

## 3. 通用优化建议

### 建议 1: 添加日志系统
```python
import logging

# 在两个文件中都添加日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(CONFIG_DIR / "tvplayer.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)
```

### 建议 2: 配置文件统一
两个项目使用不同的配置目录：
- `tv_player_desktop.py`: `~/.tvplayer_android_port`
- `tv_player_mpv.py`: `~/.tv_player`

建议统一为 `~/.tvplayer`

### 建议 3: 添加版本检测
检测 mpv 版本，如果版本过旧给出提示

### 建议 4: 频道去重优化
**位置**: `tv_player_mpv.py` - 第 201-206 行
当前使用 set + list，可以直接用 dict：
```python
seen = {}
for c in all_channels:
    if c.url not in seen:
        seen[c.url] = c
uniq = list(seen.values())
```

## 4. 代码质量建议

### 建议 1: 类型注解一致性
`tv_player_desktop.py` 有完整的类型注解，而 `tv_player_mpv.py` 没有
建议给 `tv_player_mpv.py` 也添加类型注解

### 建议 2: 异常处理
很多地方使用 `except Exception: pass`，建议记录日志：
```python
except Exception as e:
    logger.error(f"操作失败: {e}", exc_info=True)
```

### 建议 3: 魔法数字提取
很多超时时间、缓冲区大小等硬编码，建议提取为常量

## 5. 功能增强建议

1. **EPG 节目单支持**: 添加电子节目指南
2. **播放历史**: 记录最近播放的频道
3. **快捷键自定义**: 允许用户自定义快捷键
4. **多语言支持**: 添加国际化支持
5. **自动更新源**: 定期检查源更新
6. **画质选择**: 对于有多个清晰度的频道，允许选择
7. **截图功能**: 添加截图快捷键
8. **录制功能**: 添加录制功能（使用 ffmpeg）

## 优先级

**高优先级**:
1. 修复 tv_player_desktop.py 代码不完整问题
2. 删除 tv_player_mpv.py 第 584 行冗余代码
3. 添加更好的错误处理和日志

**中优先级**:
4. 优化硬编码规则为配置文件
5. 优化 IPC 性能
6. 优化测速功能

**低优先级**:
7. 添加类型注解
8. 功能增强
