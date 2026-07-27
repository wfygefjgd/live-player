#!/usr/bin/env python3
"""
频道线路验证和筛选工具
用于测试频道的所有线路，过滤出真正可播放的线路
"""

import json
import sys
import subprocess
import concurrent.futures
import time
from pathlib import Path

# 配置
TIMEOUT = 8  # 每个线路测试超时时间（秒）
MAX_WORKERS = 10  # 并发测试数
MIN_VALID_URLS = 1  # 频道至少要有1个有效线路才保留

def test_stream_url(url, timeout=TIMEOUT):
    """
    使用 ffprobe 测试流媒体 URL 是否可播放
    返回: (url, is_valid, error_message)
    """
    try:
        cmd = [
            'ffprobe',
            '-v', 'error',
            '-select_streams', 'v:0',
            '-show_entries', 'stream=codec_type',
            '-of', 'default=noprint_wrappers=1:nokey=1',
            '-timeout', str(timeout * 1000000),  # 微秒
            url
        ]

        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout + 2,
            text=True
        )

        if result.returncode == 0 and result.stdout.strip() == 'video':
            return (url, True, None)
        else:
            error = result.stderr[:200] if result.stderr else "No video stream"
            return (url, False, error)

    except subprocess.TimeoutExpired:
        return (url, False, "Timeout")
    except FileNotFoundError:
        print("❌ 错误: 未找到 ffprobe，请先安装 ffmpeg")
        sys.exit(1)
    except Exception as e:
        return (url, False, str(e)[:200])

def validate_channel_urls(channel_name, urls):
    """
    验证一个频道的所有线路
    返回: 有效的 URL 列表
    """
    print(f"\n📺 测试频道: {channel_name} ({len(urls)} 个线路)")

    valid_urls = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(test_stream_url, url): url for url in urls}

        for i, future in enumerate(concurrent.futures.as_completed(futures), 1):
            url = futures[future]
            url_result, is_valid, error = future.result()

            if is_valid:
                print(f"  ✅ [{i}/{len(urls)}] 有效")
                valid_urls.append(url)
            else:
                error_short = error[:50] + "..." if error and len(error) > 50 else error
                print(f"  ❌ [{i}/{len(urls)}] 失败: {error_short}")

    print(f"  📊 结果: {len(valid_urls)}/{len(urls)} 个线路有效")
    return valid_urls

def filter_channels(input_file, output_file):
    """
    读取频道 JSON，验证所有线路，输出筛选后的结果
    """
    print(f"📖 读取频道文件: {input_file}")

    with open(input_file, 'r', encoding='utf-8') as f:
        data = json.load(f)

    channels = data.get('channels', [])
    total_channels = len(channels)
    print(f"📊 共 {total_channels} 个频道")
    print("=" * 60)

    filtered_channels = []
    start_time = time.time()

    for i, channel in enumerate(channels, 1):
        name = channel.get('name', 'Unknown')
        group = channel.get('group', '')
        urls = channel.get('urls', [])

        print(f"\n[{i}/{total_channels}] {name} (分组: {group})")

        if not urls:
            print("  ⚠️  跳过: 无线路")
            continue

        valid_urls = validate_channel_urls(name, urls)

        if len(valid_urls) >= MIN_VALID_URLS:
            filtered_channels.append({
                'name': name,
                'group': group,
                'urls': valid_urls
            })
            print(f"  ✅ 保留频道 ({len(valid_urls)} 个有效线路)")
        else:
            print(f"  ❌ 舍弃频道 (有效线路不足 {MIN_VALID_URLS})")

    elapsed = time.time() - start_time
    print("\n" + "=" * 60)
    print(f"✅ 验证完成! 耗时: {elapsed:.1f} 秒")
    print(f"📊 保留: {len(filtered_channels)}/{total_channels} 个频道")

    # 保存结果
    output_data = {'channels': filtered_channels}
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(output_data, f, ensure_ascii=False, indent=2)

    print(f"💾 已保存到: {output_file}")

    # 统计
    total_urls_before = sum(len(ch.get('urls', [])) for ch in channels)
    total_urls_after = sum(len(ch.get('urls', [])) for ch in filtered_channels)
    print(f"📊 线路统计: {total_urls_after}/{total_urls_before} 条线路有效")

if __name__ == '__main__':
    script_dir = Path(__file__).parent.parent

    # 支持命令行参数指定输入文件
    if len(sys.argv) > 1:
        input_file = Path(sys.argv[1])
        output_file = input_file.parent / f"{input_file.stem}-filtered.json"
    else:
        input_file = script_dir / 'iptv-mirrors' / 'merged-all-sources.json'
        output_file = script_dir / 'iptv-mirrors' / 'merged-all-sources-filtered.json'

    if not input_file.exists():
        print(f"❌ 错误: 找不到输入文件 {input_file}")
        sys.exit(1)

    print("🚀 开始验证和筛选频道线路...")
    print(f"📁 输入文件: {input_file}")
    print(f"📁 输出文件: {output_file}")
    print(f"⚙️  配置: 超时 {TIMEOUT}s, 并发 {MAX_WORKERS}, 最少有效线路 {MIN_VALID_URLS}")
    print("=" * 60)

    filter_channels(input_file, output_file)
