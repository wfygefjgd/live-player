# 频道源验证工具

## 功能

本地验证所有频道源，生成预验证的频道列表，减少客户端首次启动时的验证时间。

## 使用方法

### 1. 安装依赖

```bash
pip install aiohttp
```

### 2. 准备频道数据

你需要一个包含所有频道的 JSON 文件，格式如下：

```json
[
  {
    "name": "CCTV1",
    "group": "央视频道",
    "urls": [
      "http://example.com/cctv1.m3u8",
      "http://example2.com/cctv1.m3u8"
    ]
  }
]
```

### 3. 运行验证

```bash
python validate_channels.py 输入文件.json 输出文件.json
```

示例：

```bash
# 从应用内获取当前频道列表
python validate_channels.py channels.json validated-channels.json
```

### 4. 参数调整

可以在脚本开头修改这些参数：

- `TIMEOUT` - 每个请求超时时间（默认3秒）
- `CONCURRENT` - 并发数（默认50）
- `MAX_URLS_PER_CHANNEL` - 每个频道最多保留几个可用源（默认5个）

### 5. 输出结果

生成的 `validated-channels.json` 包含：

```json
{
  "channels": [
    {
      "name": "CCTV1",
      "group": "央视频道",
      "urls": [
        "http://verified-url-1.com/cctv1.m3u8",
        "http://verified-url-2.com/cctv1.m3u8"
      ]
    }
  ],
  "metadata": {
    "total_channels": 900,
    "valid_channels": 850,
    "total_urls_tested": 5400,
    "total_valid_urls": 2100,
    "validated_at": "2026-07-25T10:30:00",
    "max_urls_per_channel": 5
  }
}
```

### 6. 部署到应用

将生成的 `validated-channels.json` 放到：
1. GitHub 仓库根目录
2. 或者 CDN
3. 或者 GitHub Release 附件

客户端启动时优先下载这个文件。

## 性能预估

假设：
- 900个频道
- 每频道平均10个源
- 每频道验证到找够5个可用源就停止
- 假设30%成功率，平均需要验证每频道15个源

预计：
- 并发50，超时3秒
- 总验证时间：约 10-15 分钟
- 生成的文件大小：约 200-500 KB

## 更新频率

建议每周运行一次，保持源的新鲜度。

## 高级用法

### 只验证前N个源

修改脚本中的验证逻辑：

```python
for url in channel.get('urls', [])[:5]:  # 只验证前5个
    # ...
```

### 导出失败的源

在脚本末尾添加：

```python
failed_urls = [url for ch in channels for url in ch['urls'] 
               if url not in result['valid_urls']]
with open('failed-urls.txt', 'w') as f:
    f.write('\n'.join(failed_urls))
```
