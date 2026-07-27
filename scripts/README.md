# TVPlayer 频道筛选工具使用说明

## 📋 功能说明

本工具集用于从多个 IPTV 源下载、合并并验证频道线路，筛选出真正可播放的频道。

## 🔧 前置要求

### 1. Python 依赖
```bash
pip install requests
```

### 2. FFmpeg 安装（用于验证线路）

**Windows:**
- 使用 Chocolatey: `choco install ffmpeg`
- 或从官网下载: https://ffmpeg.org/download.html
- 下载后解压，将 `bin` 目录添加到系统 PATH

**macOS:**
```bash
brew install ffmpeg
```

**Linux:**
```bash
# Ubuntu/Debian
sudo apt install ffmpeg

# CentOS/RHEL
sudo yum install ffmpeg
```

## 📝 使用步骤

### 方式一：一键运行（推荐）

运行完整流程，自动完成下载、合并和验证：

```bash
python scripts/run_full_filter.py
```

### 方式二：分步运行

**步骤 1: 下载并合并所有预置源**
```bash
python scripts/download_and_merge_sources.py
```
输出文件: `iptv-mirrors/merged-all-sources.json`

**步骤 2: 验证和筛选频道线路**
```bash
python scripts/validate_and_filter_channels.py
```
输出文件: `iptv-mirrors/merged-all-sources-filtered.json`

你也可以验证自定义文件：
```bash
python scripts/validate_and_filter_channels.py path/to/your/channels.json
```

## ⚙️ 配置参数

在 `validate_and_filter_channels.py` 中可以调整：

```python
TIMEOUT = 8          # 每个线路测试超时时间（秒）
MAX_WORKERS = 10     # 并发测试数量
MIN_VALID_URLS = 1   # 频道至少需要多少个有效线路才保留
```

## 📊 当前数据统计

- **预置源数量**: 8 个
- **合并后频道数**: 2164 个
- **合并后线路数**: 4391 条
- **平均每频道线路数**: 2.0 条

## 🎯 预置源列表

1. Validated GitHub mirror (476 频道)
2. Guovin 自动筛选源 (1807 频道)
3. vbskycn 双栈源 (499 频道)
4. fanmingming IPv6 源 (82 频道)
5. BurningC4 中国源 (58 频道)
6. zbefine 2026 维护源 (1286 频道)
7. suxuang IPv6 源 (862 频道)

## ⏱️ 预计耗时

- 下载合并: 约 1-2 分钟
- 验证筛选: 约 30-60 分钟（取决于网络和并发数）

## 📁 输出文件

- `merged-all-sources.json`: 合并后的所有频道（未验证）
- `merged-all-sources-filtered.json`: 验证后的可播放频道（推荐使用）

## 💡 后续步骤

验证完成后，你可以：

1. 将 `merged-all-sources-filtered.json` 转换为 M3U 格式
2. 更新 iOS 项目中的 `validated-channels.json`
3. 提交到 GitHub 并触发 iOS 编译
