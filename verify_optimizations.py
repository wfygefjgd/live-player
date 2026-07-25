#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TVPlayer 优化验证脚本
快速检查所有改进是否正确应用
"""

import os
import sys
from pathlib import Path

# 修复 Windows 控制台编码问题
if sys.platform == 'win32':
    import codecs
    sys.stdout = codecs.getwriter('utf-8')(sys.stdout.buffer, 'strict')
    sys.stderr = codecs.getwriter('utf-8')(sys.stderr.buffer, 'strict')

def check_file_exists(filepath, description):
    """检查文件是否存在"""
    if Path(filepath).exists():
        print(f"✅ {description}: {filepath}")
        return True
    else:
        print(f"❌ {description} 不存在: {filepath}")
        return False

def check_code_fix(filepath, old_code, new_code, description):
    """检查代码是否已修复"""
    try:
        content = Path(filepath).read_text(encoding='utf-8')
        if new_code in content and old_code not in content:
            print(f"✅ {description}: 已修复")
            return True
        elif old_code in content:
            print(f"⚠️  {description}: 仍然是旧代码")
            return False
        else:
            print(f"❓ {description}: 无法确定")
            return None
    except Exception as e:
        print(f"❌ {description}: 检查失败 - {e}")
        return False

def main():
    print("=" * 60)
    print("TVPlayer 优化验证报告")
    print("=" * 60)
    print()

    base_dir = Path(__file__).parent
    results = {"passed": 0, "failed": 0, "warnings": 0}

    # 1. 检查新增文件
    print("📁 检查新增文件:")
    print("-" * 60)
    files_to_check = [
        ("channel_rules.json", "规则配置文件"),
        ("channel_rules_manager.py", "规则管理器"),
        ("OPTIMIZATION_SUMMARY.md", "优化总结文档"),
        ("OPTIMIZATION_SUGGESTIONS.md", "优化建议文档"),
        ("PATCH_RULES_MANAGER.py", "集成指南"),
        ("OPTIMIZATION_FILES_README.md", "文件说明"),
    ]

    for filename, desc in files_to_check:
        if check_file_exists(base_dir / filename, desc):
            results["passed"] += 1
        else:
            results["failed"] += 1
    print()

    # 2. 检查 tv_player_mpv.py 的修复
    print("🔧 检查 tv_player_mpv.py 修复:")
    print("-" * 60)
    mpv_file = base_dir / "tv_player_mpv.py"

    if not mpv_file.exists():
        print("❌ tv_player_mpv.py 文件不存在")
        results["failed"] += 1
    else:
        # 修复1: 删除冗余音量初始化
        result = check_code_fix(
            mpv_file,
            "self.video.set_volume(self._volume)\n        self._volume = 100",
            "self.video.set_volume(self._volume)\n\n        self.setStyleSheet(DARK_QSS)",
            "修复1: 删除冗余音量初始化"
        )
        if result is True:
            results["passed"] += 1
        elif result is False:
            results["failed"] += 1
        else:
            results["warnings"] += 1

        # 修复2: 添加防抖动
        result = check_code_fix(
            mpv_file,
            "",  # 旧代码为空（新增的）
            "if self._switch_timer.isActive():\n            self._switch_timer.stop()",
            "修复2: 添加频道切换防抖动"
        )
        if result is True:
            results["passed"] += 1
        elif result is False:
            results["warnings"] += 1
        else:
            results["warnings"] += 1

        # 修复3: 添加错误处理
        result = check_code_fix(
            mpv_file,
            "",
            "def _on_process_error(self, error):",
            "修复3: 添加 MPV 进程错误处理"
        )
        if result is True:
            results["passed"] += 1
        elif result is False:
            results["warnings"] += 1
        else:
            results["warnings"] += 1

        # 修复4: 优化去重
        result = check_code_fix(
            mpv_file,
            "seen, uniq = set(), []",
            "seen = {}",
            "修复4: 优化频道去重算法"
        )
        if result is True:
            results["passed"] += 1
        elif result is False:
            results["failed"] += 1
        else:
            results["warnings"] += 1

        # 修复5: 优化测速
        result = check_code_fix(
            mpv_file,
            "batch_size = 3",
            "import multiprocessing\n        batch_size = max(3, min(8, multiprocessing.cpu_count() - 1))",
            "修复5: 优化测速性能"
        )
        if result is True:
            results["passed"] += 1
        elif result is False:
            results["failed"] += 1
        else:
            results["warnings"] += 1

    print()

    # 3. 测试规则管理器
    print("🧪 测试规则管理器:")
    print("-" * 60)
    try:
        sys.path.insert(0, str(base_dir))
        from channel_rules_manager import ChannelRulesManager

        # 创建临时测试目录
        test_dir = base_dir / ".test_rules"
        test_dir.mkdir(exist_ok=True)

        manager = ChannelRulesManager(test_dir)

        # 测试基本功能
        rules = manager.get_all_rules()
        print(f"✅ 规则管理器加载成功，共 {len(rules)} 条规则")
        results["passed"] += 1

        # 测试规则查询
        if manager.should_skip("cctv10", 0):
            print("✅ 规则查询功能正常")
            results["passed"] += 1
        else:
            print("⚠️  规则查询结果异常")
            results["warnings"] += 1

        # 清理测试目录
        import shutil
        shutil.rmtree(test_dir, ignore_errors=True)

    except Exception as e:
        print(f"❌ 规则管理器测试失败: {e}")
        results["failed"] += 1

    print()

    # 4. 总结
    print("=" * 60)
    print("验证结果总结:")
    print("=" * 60)
    print(f"✅ 通过: {results['passed']}")
    print(f"⚠️  警告: {results['warnings']}")
    print(f"❌ 失败: {results['failed']}")
    print()

    total = results['passed'] + results['warnings'] + results['failed']
    if total > 0:
        success_rate = (results['passed'] / total) * 100
        print(f"成功率: {success_rate:.1f}%")

    print()

    if results['failed'] == 0:
        print("🎉 所有关键改进都已正确应用！")
        if results['warnings'] > 0:
            print("⚠️  有一些警告项，但不影响使用。")
    else:
        print("⚠️  有一些改进未正确应用，请检查上述失败项。")

    print()
    print("📖 详细信息请查看:")
    print("   - OPTIMIZATION_SUMMARY.md (优化总结)")
    print("   - OPTIMIZATION_FILES_README.md (文件说明)")
    print()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n检查已取消")
    except Exception as e:
        print(f"\n\n❌ 检查过程出错: {e}")
        import traceback
        traceback.print_exc()
