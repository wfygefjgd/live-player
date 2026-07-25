#!/usr/bin/env python3
"""
频道源验证脚本
一次性验证所有频道源，生成预验证的频道列表
"""

import asyncio
import aiohttp
import json
from typing import List, Dict, Tuple
from datetime import datetime
import sys

# 配置
TIMEOUT = 3  # 每个请求超时时间（秒）
CONCURRENT = 50  # 并发数
MAX_URLS_PER_CHANNEL = 5  # 每个频道最多保留几个可用源

async def validate_url(session: aiohttp.ClientSession, url: str) -> bool:
    """验证单个 URL 是否可用"""
    try:
        async with session.head(
            url,
            timeout=aiohttp.ClientTimeout(total=TIMEOUT),
            allow_redirects=True,
            headers={'User-Agent': 'Mozilla/5.0'}
        ) as response:
            return response.status == 200
    except:
        return False

async def validate_channel(
    session: aiohttp.ClientSession,
    channel: Dict,
    progress_callback
) -> Tuple[Dict, int, int]:
    """验证单个频道的所有源"""
    valid_urls = []
    total = len(channel.get('urls', []))
    tested = 0

    for url in channel.get('urls', []):
        is_valid = await validate_url(session, url)
        tested += 1
        progress_callback()

        if is_valid:
            valid_urls.append(url)
            # 找到足够数量的可用源就停止
            if len(valid_urls) >= MAX_URLS_PER_CHANNEL:
                break

    # 返回验证后的频道（只保留可用源）
    validated_channel = channel.copy()
    validated_channel['urls'] = valid_urls

    return validated_channel, tested, len(valid_urls)

async def validate_all_channels(channels: List[Dict]) -> Dict:
    """验证所有频道"""
    total_urls = sum(len(ch.get('urls', [])) for ch in channels)
    tested_count = 0

    print(f"开始验证 {len(channels)} 个频道，共 {total_urls} 个源...")
    print(f"并发数: {CONCURRENT}, 超时: {TIMEOUT}秒, 每频道最多保留: {MAX_URLS_PER_CHANNEL}个源")
    print("-" * 60)

    def progress():
        nonlocal tested_count
        tested_count += 1
        if tested_count % 50 == 0:
            progress_pct = (tested_count / total_urls) * 100
            print(f"进度: {tested_count}/{total_urls} ({progress_pct:.1f}%)")

    validated_channels = []
    total_valid = 0

    connector = aiohttp.TCPConnector(limit=CONCURRENT, limit_per_host=10)
    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = []
        for channel in channels:
            task = validate_channel(session, channel, progress)
            tasks.append(task)

        results = await asyncio.gather(*tasks)

        for validated_ch, tested, valid in results:
            if valid > 0:  # 只保留至少有1个可用源的频道
                validated_channels.append(validated_ch)
                total_valid += valid

    return {
        'channels': validated_channels,
        'metadata': {
            'total_channels': len(channels),
            'valid_channels': len(validated_channels),
            'total_urls_tested': tested_count,
            'total_valid_urls': total_valid,
            'validated_at': datetime.now().isoformat(),
            'max_urls_per_channel': MAX_URLS_PER_CHANNEL
        }
    }

def load_channels_from_sources(sources_file: str) -> List[Dict]:
    """从源配置文件加载频道列表"""
    with open(sources_file, 'r', encoding='utf-8') as f:
        sources = json.load(f)

    # 假设格式是包含多个源的数组
    all_channels = []
    for source in sources:
        if 'channels' in source:
            all_channels.extend(source['channels'])

    return all_channels

async def main():
    if len(sys.argv) < 2:
        print("用法: python validate_channels.py <输入JSON文件> [输出文件]")
        print("示例: python validate_channels.py channels.json validated-channels.json")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else 'validated-channels.json'

    print(f"读取频道数据: {input_file}")

    # 读取原始频道数据
    with open(input_file, 'r', encoding='utf-8') as f:
        data = json.load(f)

    # 提取频道列表
    if isinstance(data, list):
        channels = data
    elif 'channels' in data:
        channels = data['channels']
    else:
        print("错误: 无法解析频道数据")
        sys.exit(1)

    # 验证
    start_time = datetime.now()
    result = await validate_all_channels(channels)
    elapsed = (datetime.now() - start_time).total_seconds()

    # 输出结果
    print("-" * 60)
    print(f"✅ 验证完成！耗时: {elapsed:.1f}秒")
    print(f"原始频道数: {result['metadata']['total_channels']}")
    print(f"可用频道数: {result['metadata']['valid_channels']}")
    print(f"测试源数量: {result['metadata']['total_urls_tested']}")
    print(f"可用源数量: {result['metadata']['total_valid_urls']}")

    # 保存结果
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(f"\n结果已保存到: {output_file}")

if __name__ == '__main__':
    asyncio.run(main())
