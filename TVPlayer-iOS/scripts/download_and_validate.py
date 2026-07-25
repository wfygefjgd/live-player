#!/usr/bin/env python3
"""
完整的频道验证流程：
1. 从 PRESET_SOURCES 下载所有 M3U 文件
2. 解析 M3U 提取频道和 URL
3. 验证所有 URL 可用性
4. 生成预验证的频道列表
"""

import asyncio
import aiohttp
import json
import re
from typing import List, Dict, Tuple
from datetime import datetime
from collections import defaultdict

# 预设源列表（从 PlayerViewModel.swift 复制）
PRESET_SOURCES = [
    ("BurningC4 CDN", "https://iptv.burningc4.com/TV-IPV4.m3u"),
    ("dongyubin 体育", "https://ghfast.top/raw.githubusercontent.com/dongyubin/IPTV/main/IPTV.m3u"),
    ("肥羊 4K", "https://ghfast.top/raw.githubusercontent.com/gaotianliuyun/youshandefeiyang/main/live.m3u"),
    ("hujingguang", "https://ghfast.top/raw.githubusercontent.com/hujingguang/ChinaIPTV/main/grouped.m3u8"),
    ("fanmingming IPv6", "https://ghfast.top/raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"),
    ("best-fan 全量", "https://gh-proxy.com/https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8"),
    ("kongkongyo CCTV", "https://ghfast.top/raw.githubusercontent.com/kongkongyo/m3u8/main/iptv.m3u"),
    ("iptv-org 中国", "https://ghfast.top/raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u"),
]

# 配置
TIMEOUT = 2  # 验证超时时间（秒）
CONCURRENT = 30  # 并发数
MAX_URLS_PER_CHANNEL = 3  # 每个频道最多保留几个可用源
STAGE1_CONCURRENT = 50  # 第一阶段并发数

def parse_m3u(content: str) -> List[Dict]:
    """解析 M3U 文件，提取频道和 URL"""
    channels = defaultdict(lambda: {"name": "", "group": "", "urls": []})

    lines = content.strip().split('\n')
    i = 0

    while i < len(lines):
        line = lines[i].strip()

        # 跳过空行和 #EXTM3U
        if not line or line == '#EXTM3U':
            i += 1
            continue

        # 解析 #EXTINF 行
        if line.startswith('#EXTINF:'):
            # 提取频道名和分组
            name_match = re.search(r'tvg-name="([^"]*)"', line)
            group_match = re.search(r'group-title="([^"]*)"', line)

            # 如果没有 tvg-name，尝试从行尾提取
            if not name_match:
                parts = line.split(',')
                if len(parts) > 1:
                    name = parts[-1].strip()
                else:
                    name = "未知频道"
            else:
                name = name_match.group(1)

            group = group_match.group(1) if group_match else "其他"

            # 读取下一行（URL）
            i += 1
            if i < len(lines):
                url = lines[i].strip()
                if url and (url.startswith('http://') or url.startswith('https://')):
                    # 使用频道名作为 key 来合并相同频道
                    channels[name]["name"] = name
                    channels[name]["group"] = group
                    channels[name]["urls"].append(url)

        i += 1

    # 转换为列表
    return [{"name": v["name"], "group": v["group"], "urls": v["urls"]}
            for v in channels.values() if v["urls"]]

async def download_m3u(session: aiohttp.ClientSession, name: str, url: str) -> Tuple[str, List[Dict]]:
    """下载并解析 M3U 文件"""
    print(f"[下载] {name}")
    try:
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=30)) as response:
            if response.status == 200:
                content = await response.text()
                channels = parse_m3u(content)
                print(f"[成功] {name}: 解析到 {len(channels)} 个频道")
                return (name, channels)
            else:
                print(f"[失败] {name}: HTTP {response.status}")
                return (name, [])
    except Exception as e:
        print(f"[失败] {name}: {str(e)}")
        return (name, [])

async def validate_url_stage1(session: aiohttp.ClientSession, url: str) -> bool:
    """第一阶段：快速格式检查（GET 前 8KB）"""
    try:
        async with session.get(
            url,
            timeout=aiohttp.ClientTimeout(total=3),
            allow_redirects=True,
            headers={
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Referer': url.split('?')[0]
            }
        ) as response:
            if response.status != 200:
                return False

            # 读取前 8KB
            content = await response.content.read(8192)
            text = content.decode('utf-8', errors='ignore')

            # 检查 M3U8 格式标记
            return '#EXTM3U' in text or '#EXTINF' in text or '.ts' in text
    except:
        return False

async def validate_url_stage2(session: aiohttp.ClientSession, url: str) -> bool:
    """第二阶段：下载 TS 分片验证真实播放能力"""
    try:
        # 下载 M3U8 内容
        async with session.get(
            url,
            timeout=aiohttp.ClientTimeout(total=5),
            allow_redirects=True,
            headers={
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Referer': url.split('?')[0]
            }
        ) as response:
            if response.status != 200:
                return False

            content = await response.text()

            # 检查是否是 master playlist（包含 #EXT-X-STREAM-INF）
            if '#EXT-X-STREAM-INF' in content:
                # 解析第一个子流 URL
                for line in content.split('\n'):
                    line = line.strip()
                    if line and not line.startswith('#'):
                        if line.startswith('http://') or line.startswith('https://'):
                            sub_url = line
                        else:
                            base_url = url.rsplit('/', 1)[0]
                            sub_url = f"{base_url}/{line}"

                        # 递归验证子流
                        return await validate_url_stage2(session, sub_url)
                return False

            # 解析 M3U8，找到第一个 .ts 文件
            ts_url = None
            for line in content.split('\n'):
                line = line.strip()
                if line and not line.startswith('#'):
                    if line.endswith('.ts') or '.ts?' in line:
                        # 处理相对路径
                        if line.startswith('http://') or line.startswith('https://'):
                            ts_url = line
                        else:
                            base_url = url.rsplit('/', 1)[0]
                            ts_url = f"{base_url}/{line}"
                        break

            if not ts_url:
                return False

            # 下载 TS 分片前 100KB 并检查文件头
            async with session.get(
                ts_url,
                timeout=aiohttp.ClientTimeout(total=8),
                allow_redirects=True,
                headers={
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                    'Referer': url
                }
            ) as ts_response:
                if ts_response.status != 200:
                    return False

                ts_data = await ts_response.content.read(102400)  # 100KB

                # 检查 TS 文件魔术字节（0x47）
                if len(ts_data) < 188:
                    return False

                # TS 包每 188 字节开始都是 0x47
                return ts_data[0] == 0x47
    except:
        return False

async def validate_channel(
    session: aiohttp.ClientSession,
    channel: Dict,
    progress_callback
) -> Tuple[Dict, int, int, int]:
    """两阶段验证单个频道的所有源"""
    stage2_passed = []
    total = len(channel.get('urls', []))
    tested = 0
    stage1_passed_count = 0

    # 直接进入第二阶段验证（跳过第一阶段）
    for url in channel.get('urls', []):
        tested += 1
        progress_callback(1)

        is_valid = await validate_url_stage2(session, url)
        if is_valid:
            stage2_passed.append(url)
            stage1_passed_count += 1
            progress_callback(2)
            # 找到足够数量的可用源就停止
            if len(stage2_passed) >= MAX_URLS_PER_CHANNEL:
                break

    # 返回验证后的频道（只保留通过验证的）
    validated_channel = channel.copy()
    validated_channel['urls'] = stage2_passed

    return validated_channel, tested, stage1_passed_count, len(stage2_passed)

async def main():
    print("=" * 60)
    print("TVPlayer 频道源预验证工具")
    print("=" * 60)
    print()

    # 步骤 1: 下载所有 M3U 源
    print("步骤 1/3: 下载并解析 M3U 源...")
    print("-" * 60)

    all_channels_by_source = {}

    connector = aiohttp.TCPConnector(limit=10)
    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = [download_m3u(session, name, url) for name, url in PRESET_SOURCES]
        results = await asyncio.gather(*tasks)

        for name, channels in results:
            if channels:
                all_channels_by_source[name] = channels

    print()
    print(f"[完成] 成功下载 {len(all_channels_by_source)}/{len(PRESET_SOURCES)} 个源")
    print()

    # 合并所有频道（按频道名去重）
    merged_channels = {}
    for source_name, channels in all_channels_by_source.items():
        for ch in channels:
            name = ch['name']
            if name not in merged_channels:
                merged_channels[name] = {
                    'name': name,
                    'group': ch['group'],
                    'urls': []
                }
            # 添加 URL（去重）
            for url in ch['urls']:
                if url not in merged_channels[name]['urls']:
                    merged_channels[name]['urls'].append(url)

    channels_list = list(merged_channels.values())
    total_urls = sum(len(ch['urls']) for ch in channels_list)

    print(f"[统计] 合并后:")
    print(f"   - 频道数量: {len(channels_list)}")
    print(f"   - URL 总数: {total_urls}")
    print()

    # 步骤 2: 验证所有 URL
    print("步骤 2/3: TS 分片深度验证...")
    print(f"   - 方法: 下载实际 TS 分片并检查文件头")
    print(f"   - 并发数: {CONCURRENT}")
    print(f"   - 超时: 8秒")
    print(f"   - 支持 master playlist 自动解析")
    print(f"   - 每频道最多保留: {MAX_URLS_PER_CHANNEL}个可用源")
    print("-" * 60)

    tested_count = 0
    stage2_passed_count = 0

    def progress(stage):
        nonlocal tested_count, stage2_passed_count
        if stage == 1:
            tested_count += 1
            if tested_count % 50 == 0:
                progress_pct = (tested_count / total_urls) * 100
                print(f"[验证] 进度: {tested_count}/{total_urls} ({progress_pct:.1f}%)")
        elif stage == 2:
            stage2_passed_count += 1

    validated_channels = []

    connector = aiohttp.TCPConnector(limit=CONCURRENT, limit_per_host=10)
    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = []
        for channel in channels_list:
            task = validate_channel(session, channel, progress)
            tasks.append(task)

        results = await asyncio.gather(*tasks)

        for validated_ch, tested, stage1_passed, stage2_passed in results:
            if stage2_passed > 0:  # 只保留至少有1个可用源的频道
                validated_channels.append(validated_ch)

    print()
    print("[完成] 验证完成！")
    print()

    # 步骤 3: 保存结果
    print("步骤 3/3: 保存结果...")
    print("-" * 60)

    result = {
        'channels': validated_channels,
        'metadata': {
            'total_channels': len(channels_list),
            'valid_channels': len(validated_channels),
            'total_urls_tested': tested_count,
            'valid_urls': stage2_passed_count,
            'validated_at': datetime.now().isoformat(),
            'max_urls_per_channel': MAX_URLS_PER_CHANNEL,
            'sources': [name for name, url in PRESET_SOURCES],
            'validation_method': 'TS segment download with master playlist support'
        }
    }

    output_file = 'validated-channels.json'
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print()
    print("=" * 60)
    print("[统计] 最终结果")
    print("=" * 60)
    print(f"原始频道数: {len(channels_list)}")
    print(f"可用频道数: {len(validated_channels)}")
    print(f"频道保留率: {len(validated_channels)/len(channels_list)*100:.1f}%")
    print(f"测试 URL 数: {tested_count}")
    print(f"可用 URL 数: {stage2_passed_count}")
    print(f"URL 可用率: {stage2_passed_count/tested_count*100:.1f}%")
    print()
    print(f"[完成] 结果已保存到: {output_file}")
    print("=" * 60)

if __name__ == '__main__':
    asyncio.run(main())
