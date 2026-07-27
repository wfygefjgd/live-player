#!/usr/bin/env python3
"""
完整的频道筛选流程：
1. 下载并合并所有预置源
2. 验证所有频道线路
3. 生成筛选后的结果
"""

import subprocess
import sys
from pathlib import Path

def run_script(script_name, description):
    """运行 Python 脚本"""
    print(f"\n{'='*70}")
    print(f"🔧 {description}")
    print(f"{'='*70}\n")

    script_path = Path(__file__).parent / script_name

    try:
        result = subprocess.run(
            [sys.executable, str(script_path)],
            check=True
        )
        return result.returncode == 0
    except subprocess.CalledProcessError as e:
        print(f"\n❌ 脚本执行失败: {e}")
        return False
    except Exception as e:
        print(f"\n❌ 发生错误: {e}")
        return False

def main():
    print("🚀 TVPlayer 频道筛选工具")
    print("=" * 70)
    print("流程:")
    print("  1️⃣  下载并合并所有预置源")
    print("  2️⃣  验证所有频道线路（使用 ffprobe）")
    print("  3️⃣  生成筛选后的频道列表")
    print("=" * 70)

    # 检查 ffprobe
    try:
        result = subprocess.run(
            ['ffprobe', '-version'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        if result.returncode != 0:
            raise FileNotFoundError
    except FileNotFoundError:
        print("\n⚠️  警告: 未找到 ffprobe")
        print("请先安装 ffmpeg:")
        print("  - Windows: choco install ffmpeg 或从 https://ffmpeg.org 下载")
        print("  - macOS: brew install ffmpeg")
        print("  - Linux: apt install ffmpeg 或 yum install ffmpeg")
        sys.exit(1)

    print("\n✅ ffprobe 已安装\n")

    # 步骤 1: 下载并合并源
    if not run_script('download_and_merge_sources.py', '步骤 1: 下载并合并所有预置源'):
        print("\n❌ 第一步失败，终止流程")
        sys.exit(1)

    # 步骤 2: 验证和筛选
    if not run_script('validate_and_filter_channels.py', '步骤 2: 验证和筛选频道线路'):
        print("\n❌ 第二步失败，终止流程")
        sys.exit(1)

    # 完成
    print("\n" + "=" * 70)
    print("✨ 所有步骤完成!")
    print("=" * 70)

    output_file = Path(__file__).parent.parent / 'iptv-mirrors' / 'merged-all-sources-filtered.json'
    print(f"\n📄 筛选结果: {output_file}")
    print("\n💡 下一步:")
    print("  1. 检查筛选结果")
    print("  2. 将 merged-all-sources-filtered.json 转换为 M3U 格式")
    print("  3. 更新 iOS 项目中的 validated-channels.json")
    print("  4. 重新编译应用")

if __name__ == '__main__':
    main()
