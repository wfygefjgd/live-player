#!/usr/bin/env python3
"""
下载所有预置源并合并为统一的 JSON 格式
"""

import json
import re
import requests
from pathlib import Path
from collections import defaultdict

# 所有预置源
PRESET_SOURCES = [
    ("Validated GitHub mirror", "https://raw.githubusercontent.com/wfygefjgd/live-player/main/iptv-mirrors/validated-channels.m3u"),
    ("Validated jsDelivr mirror", "https://cdn.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u"),
    ("Guovin 自动筛选源（推荐）", "https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u"),
    ("vbskycn 双栈源", "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u"),
    ("fanmingming IPv6 源", "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"),
    ("BurningC4 中国源", "https://wfygefjgd.github.io/live-player/iptv-mirrors/burningc4-chinese-iptv.m3u"),
    ("zbefine 2026 维护源", "https://wfygefjgd.github.io/live-player/iptv-mirrors/zbefine-iptv.m3u"),
    ("suxuang IPv6 源", "https://wfygefjgd.github.io/live-player/iptv-mirrors/suxuang-myiptv.m3u"),
]

def download_m3u(url, timeout=30):
    """下载 M3U 文件"""
    try:
        print(f"  📥 下载中...")
        headers = {'User-Agent': 'Mozilla/5.0'}
        response = requests.get(url, timeout=timeout, headers=headers)
        response.raise_for_status()
        return response.text
    except Exception as e:
        print(f"  ❌ 下载失败: {e}")
        return None

def parse_m3u(content):
    """解析 M3U 内容为频道列表"""
    channels = []
    lines = content.strip().split('\n')

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        if line.startswith('#EXTINF'):
            # 解析频道信息
            name = None
            group = "其他"

            # 提取 tvg-name 或逗号后的名称
            name_match = re.search(r'tvg-name="([^"]+)"', line)
            if name_match:
                name = name_match.group(1)
            else:
                # 逗号后的名称
                comma_parts = line.split(',', 1)
                if len(comma_parts) == 2:
                    name = comma_parts[1].strip()

            # 提取分组
            group_match = re.search(r'group-title="([^"]+)"', line)
            if group_match:
                group = group_match.group(1)

            # 下一行是 URL
            i += 1
            if i < len(lines):
                url = lines[i].strip()
                if url and not url.startswith('#') and name:
                    channels.append({
                        'name': name,
                        'group': group,
                        'url': url
                    })

        i += 1

    return channels

def merge_channels(all_sources_channels):
    """
    合并多个源的频道，按频道名称去重并收集所有线路
    """
    merged = defaultdict(lambda: {'group': '其他', 'urls': []})

    for channels in all_sources_channels:
        for ch in channels:
            name = ch['name']
            url = ch['url']
            group = ch.get('group', '其他')

            # 第一次遇到该频道，设置分组
            if not merged[name]['group'] or merged[name]['group'] == '其他':
                merged[name]['group'] = group

            # 添加 URL（去重）
            if url not in merged[name]['urls']:
                merged[name]['urls'].append(url)

    # 转换为列表格式
    result = []
    for name, data in merged.items():
        result.append({
            'name': name,
            'group': data['group'],
            'urls': data['urls']
        })

    return result

def main():
    print("🚀 开始下载和合并所有预置源...")
    print("=" * 70)

    all_channels = []

    for i, (source_name, url) in enumerate(PRESET_SOURCES, 1):
        print(f"\n[{i}/{len(PRESET_SOURCES)}] {source_name}")
        print(f"  🔗 {url}")

        # 跳过重复的镜像源
        if "jsDelivr mirror" in source_name:
            print("  ⏭️  跳过 (与 GitHub mirror 重复)")
            continue

        content = download_m3u(url)
        if not content:
            continue

        channels = parse_m3u(content)
        print(f"  ✅ 解析成功: {len(channels)} 个频道")
        all_channels.append(channels)

    print("\n" + "=" * 70)
    print("🔄 开始合并频道...")

    merged_channels = merge_channels(all_channels)

    # 按分组和名称排序
    merged_channels.sort(key=lambda x: (x['group'], x['name']))

    # 统计
    total_channels = len(merged_channels)
    total_urls = sum(len(ch['urls']) for ch in merged_channels)
    avg_urls = total_urls / total_channels if total_channels > 0 else 0

    print(f"✅ 合并完成!")
    print(f"📊 统计:")
    print(f"   - 总频道数: {total_channels}")
    print(f"   - 总线路数: {total_urls}")
    print(f"   - 平均每频道线路数: {avg_urls:.1f}")

    # 分组统计
    groups = defaultdict(int)
    for ch in merged_channels:
        groups[ch['group']] += 1

    print(f"\n📂 分组统计:")
    for group, count in sorted(groups.items(), key=lambda x: -x[1]):
        print(f"   - {group}: {count} 个频道")

    # 保存结果
    output_file = Path(__file__).parent.parent / 'iptv-mirrors' / 'merged-all-sources.json'
    output_data = {'channels': merged_channels}

    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(output_data, f, ensure_ascii=False, indent=2)

    print(f"\n💾 已保存到: {output_file}")
    print("\n✨ 下一步: 运行验证脚本筛选可用线路")
    print(f"   python scripts/validate_and_filter_channels.py {output_file}")

if __name__ == '__main__':
    main()
