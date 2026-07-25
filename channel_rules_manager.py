#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
频道规则管理器 - 用于替代硬编码的规则
可以被 tv_player_desktop.py 和其他播放器复用
"""

from __future__ import annotations
import json
from pathlib import Path
from typing import Dict, List, Optional, Set


class ChannelRulesManager:
    """频道规则管理器 - 管理频道线路跳过规则"""

    def __init__(self, config_dir: Path):
        self.config_dir = config_dir
        self.rules_file = config_dir / "channel_rules.json"
        self._skip_rules: Dict[str, Set[int]] = {}
        self._load_rules()

    def _load_rules(self) -> None:
        """从配置文件加载规则"""
        if not self.rules_file.exists():
            self._create_default_rules()

        try:
            with open(self.rules_file, 'r', encoding='utf-8') as f:
                data = json.load(f)

            self._skip_rules.clear()
            for rule in data.get("skip_rules", []):
                key = rule.get("key", "").strip()
                indices = rule.get("skip_indices", [])
                if key and indices:
                    self._skip_rules[key] = set(indices)
        except Exception as e:
            print(f"加载规则失败: {e}, 使用默认规则")
            self._create_default_rules()

    def _create_default_rules(self) -> None:
        """创建默认规则文件"""
        default_rules = {
            "version": "1.0",
            "description": "频道线路跳过规则配置",
            "skip_rules": [
                {
                    "key": "cctv10",
                    "skip_indices": [0],
                    "reason": "第一条线路不稳定"
                },
                {
                    "key": "cctv14",
                    "skip_indices": [0],
                    "reason": "第一条线路不稳定"
                },
                {
                    "key": "cctv13",
                    "skip_indices": [0, 1, 2],
                    "reason": "前三条线路不稳定"
                },
                {
                    "key": "北京",
                    "skip_indices": [0],
                    "reason": "第一条线路不稳定"
                },
                {
                    "key": "湖南",
                    "skip_indices": [0, 1],
                    "reason": "前两条线路不稳定"
                }
            ],
            "notes": [
                "key: 频道标识符（由 M3UParser.normalize_name 生成）",
                "skip_indices: 要跳过的线路索引（从 0 开始）",
                "reason: 跳过原因（可选，仅供参考）"
            ]
        }

        try:
            self.config_dir.mkdir(parents=True, exist_ok=True)
            with open(self.rules_file, 'w', encoding='utf-8') as f:
                json.dump(default_rules, f, ensure_ascii=False, indent=2)

            # 加载到内存
            for rule in default_rules["skip_rules"]:
                key = rule["key"]
                self._skip_rules[key] = set(rule["skip_indices"])
        except Exception as e:
            print(f"创建默认规则失败: {e}")

    def should_skip(self, channel_key: str, line_index: int) -> bool:
        """
        检查是否应该跳过某个频道的指定线路

        Args:
            channel_key: 频道标识符（由 M3UParser.normalize_name 生成）
            line_index: 线路索引（从 0 开始）

        Returns:
            True 如果应该跳过，False 否则
        """
        if channel_key not in self._skip_rules:
            return False
        return line_index in self._skip_rules[channel_key]

    def add_rule(self, channel_key: str, skip_indices: List[int], reason: str = "") -> None:
        """
        添加或更新规则

        Args:
            channel_key: 频道标识符
            skip_indices: 要跳过的线路索引列表
            reason: 跳过原因（可选）
        """
        self._skip_rules[channel_key] = set(skip_indices)
        self._save_rules(reason)

    def remove_rule(self, channel_key: str) -> None:
        """删除规则"""
        if channel_key in self._skip_rules:
            del self._skip_rules[channel_key]
            self._save_rules()

    def get_all_rules(self) -> Dict[str, Set[int]]:
        """获取所有规则"""
        return dict(self._skip_rules)

    def _save_rules(self, default_reason: str = "") -> None:
        """保存规则到文件"""
        try:
            # 读取现有文件以保留注释和原因
            existing_rules = {}
            if self.rules_file.exists():
                with open(self.rules_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    for rule in data.get("skip_rules", []):
                        existing_rules[rule["key"]] = rule.get("reason", "")

            # 构建新的规则数据
            skip_rules = []
            for key, indices in sorted(self._skip_rules.items()):
                skip_rules.append({
                    "key": key,
                    "skip_indices": sorted(list(indices)),
                    "reason": existing_rules.get(key, default_reason)
                })

            data = {
                "version": "1.0",
                "description": "频道线路跳过规则配置",
                "skip_rules": skip_rules,
                "notes": [
                    "key: 频道标识符（由 M3UParser.normalize_name 生成）",
                    "skip_indices: 要跳过的线路索引（从 0 开始）",
                    "reason: 跳过原因（可选，仅供参考）"
                ]
            }

            with open(self.rules_file, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
        except Exception as e:
            print(f"保存规则失败: {e}")

    def reload(self) -> None:
        """重新加载规则"""
        self._load_rules()


# 示例用法
if __name__ == "__main__":
    from pathlib import Path

    # 测试规则管理器
    test_dir = Path.home() / ".tvplayer_test"
    manager = ChannelRulesManager(test_dir)

    print("当前规则:")
    for key, indices in manager.get_all_rules().items():
        print(f"  {key}: 跳过线路 {sorted(indices)}")

    # 测试规则检查
    print("\n测试规则:")
    print(f"  cctv10 线路0: {'跳过' if manager.should_skip('cctv10', 0) else '播放'}")
    print(f"  cctv10 线路1: {'跳过' if manager.should_skip('cctv10', 1) else '播放'}")
    print(f"  cctv13 线路1: {'跳过' if manager.should_skip('cctv13', 1) else '播放'}")

    # 测试添加规则
    print("\n添加新规则: cctv5 跳过线路 [0, 2]")
    manager.add_rule("cctv5", [0, 2], "测试规则")
    print(f"  cctv5 线路0: {'跳过' if manager.should_skip('cctv5', 0) else '播放'}")
    print(f"  cctv5 线路1: {'跳过' if manager.should_skip('cctv5', 1) else '播放'}")
    print(f"  cctv5 线路2: {'跳过' if manager.should_skip('cctv5', 2) else '播放'}")
