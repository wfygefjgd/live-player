#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tv_player_desktop.py 优化补丁
展示如何集成 ChannelRulesManager 来替代硬编码规则
"""

# ============================================================================
# 1. 在文件顶部导入新模块
# ============================================================================
# 在现有导入后添加：
from channel_rules_manager import ChannelRulesManager

# ============================================================================
# 2. 在 MainActivity.__init__() 中初始化规则管理器
# ============================================================================
# 在 self.storage = StorageHelper() 后添加：
# self.rules_manager = ChannelRulesManager(PREF_DIR)

# ============================================================================
# 3. 替换 should_skip_channel_line 方法
# ============================================================================
# 原方法（第 1543-1556 行）:
"""
def should_skip_channel_line(
    self, key: str, index: int, url: str
) -> bool:
    if key == "cctv10":
        return index == 0
    if key == "cctv14":
        return index == 0
    if key == "cctv13":
        return 0 <= index <= 2
    if key == "北京":
        return index == 0
    if key == "湖南":
        return 0 <= index <= 1
    return False
"""

# 新方法（简化版）:
"""
def should_skip_channel_line(
    self, key: str, index: int, url: str
) -> bool:
    return self.rules_manager.should_skip(key, index)
"""

# ============================================================================
# 4. 完整的集成示例
# ============================================================================

class MainActivity_PATCHED:
    """展示如何集成规则管理器的示例"""

    def __init__(self) -> None:
        # ... 现有初始化代码 ...

        # 添加规则管理器
        self.storage = StorageHelper()
        self.rules_manager = ChannelRulesManager(PREF_DIR)

        # ... 其余初始化代码 ...

    def should_skip_channel_line(
        self, key: str, index: int, url: str
    ) -> bool:
        """使用规则管理器检查是否跳过线路"""
        return self.rules_manager.should_skip(key, index)

    def apply_channel_line_rules(
        self, input_list: List  # 简化类型标注
    ) -> List:
        """应用频道线路规则 - 无需修改"""
        output = []
        for source in input_list:
            if source is None:
                continue
            filtered = Channel(source.name, source.group, source.key, None)
            urls = source.get_urls()
            for i, url in enumerate(urls):
                # 检查隐藏列表
                if self.storage.is_line_hidden(url):
                    continue
                # 使用规则管理器检查
                if self.should_skip_channel_line(source.key, i, url):
                    continue
                filtered.add_url(url)
            if filtered.get_source_count() > 0:
                output.append(filtered)
        return output

    # 可选：添加规则管理 UI
    def show_rules_manager_dialog(self) -> None:
        """显示规则管理对话框（可选功能）"""
        import tkinter as tk
        from tkinter import ttk, messagebox

        dlg = tk.Toplevel(self.root)
        dlg.title("频道规则管理")
        dlg.geometry("600x480")
        dlg.configure(bg="#1E1E1E")
        dlg.transient(self.root)
        dlg.grab_set()

        root_fr = tk.Frame(dlg, bg="#1E1E1E", padx=16, pady=16)
        root_fr.pack(fill=tk.BOTH, expand=True)

        # 标题
        tk.Label(
            root_fr,
            text="管理频道跳过规则",
            bg="#1E1E1E",
            fg="#E0E0E0",
            font=("", 12, "bold")
        ).pack(pady=(0, 8))

        # 规则列表
        list_frame = tk.Frame(root_fr, bg="#1E1E1E")
        list_frame.pack(fill=tk.BOTH, expand=True)

        listbox = tk.Listbox(
            list_frame,
            bg="#2a2a2a",
            fg="#E0E0E0",
            selectbackground="#094771",
            relief=tk.FLAT,
            font=("", 11),
        )
        scrollbar = tk.Scrollbar(list_frame, command=listbox.yview)
        listbox.configure(yscrollcommand=scrollbar.set)

        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        listbox.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        def refresh_list():
            listbox.delete(0, tk.END)
            rules = self.rules_manager.get_all_rules()
            for key, indices in sorted(rules.items()):
                indices_str = ", ".join(str(i) for i in sorted(indices))
                listbox.insert(tk.END, f"{key}: 跳过线路 [{indices_str}]")

        # 按钮
        btn_frame = tk.Frame(root_fr, bg="#1E1E1E")
        btn_frame.pack(fill=tk.X, pady=(8, 0))

        tk.Button(
            btn_frame,
            text="重新加载",
            bg="#0e639c",
            fg="white",
            relief=tk.FLAT,
            command=lambda: (self.rules_manager.reload(), refresh_list())
        ).pack(side=tk.LEFT, padx=(0, 4))

        tk.Button(
            btn_frame,
            text="打开配置文件",
            bg="#0e639c",
            fg="white",
            relief=tk.FLAT,
            command=lambda: self._open_rules_file()
        ).pack(side=tk.LEFT, padx=(4, 4))

        tk.Button(
            btn_frame,
            text="关闭",
            bg="#555555",
            fg="white",
            relief=tk.FLAT,
            command=dlg.destroy
        ).pack(side=tk.RIGHT)

        refresh_list()

    def _open_rules_file(self) -> None:
        """在默认编辑器中打开规则配置文件"""
        import os
        import subprocess

        rules_file = self.rules_manager.rules_file
        try:
            if os.name == 'nt':  # Windows
                os.startfile(str(rules_file))
            elif os.name == 'posix':  # Linux/Mac
                subprocess.run(['xdg-open', str(rules_file)])
        except Exception as e:
            messagebox.showerror("错误", f"无法打开文件: {e}")


# ============================================================================
# 5. 额外优化建议
# ============================================================================

"""
优化 1: 添加快捷键打开规则管理
在 setup_keys() 中添加：
    self.root.bind_all("r", lambda e: self.show_rules_manager_dialog())
    self.root.bind_all("R", lambda e: self.show_rules_manager_dialog())

优化 2: 在源管理对话框中添加规则管理按钮
在 show_source_input_dialog() 的按钮区域添加：
    tk.Button(
        actions,
        text="规则管理",
        bg="#0e639c",
        fg="white",
        relief=tk.FLAT,
        command=self.show_rules_manager_dialog
    ).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 0))

优化 3: 自动检测并提示添加规则
当用户多次跳过某个频道的某条线路时，可以提示是否添加规则：
    def track_line_skip(self, channel_key: str, line_index: int):
        # 跟踪跳过次数
        skip_key = f"{channel_key}:{line_index}"
        if not hasattr(self, '_skip_count'):
            self._skip_count = {}
        self._skip_count[skip_key] = self._skip_count.get(skip_key, 0) + 1

        # 3次后提示
        if self._skip_count[skip_key] == 3:
            result = messagebox.askyesno(
                "添加规则",
                f"检测到您多次跳过 {channel_key} 的线路 {line_index + 1}\\n"
                f"是否添加到跳过规则中？"
            )
            if result:
                current = self.rules_manager.get_all_rules().get(channel_key, set())
                current.add(line_index)
                self.rules_manager.add_rule(
                    channel_key,
                    list(current),
                    "用户手动添加"
                )
                messagebox.showinfo("成功", "规则已添加")
"""

# ============================================================================
# 6. 应用补丁的步骤
# ============================================================================

"""
步骤 1: 将 channel_rules_manager.py 放在与 tv_player_desktop.py 同目录

步骤 2: 在 tv_player_desktop.py 顶部添加导入：
    from channel_rules_manager import ChannelRulesManager

步骤 3: 在 MainActivity.__init__() 中添加（约第 618 行）：
    self.storage = StorageHelper()
    self.rules_manager = ChannelRulesManager(PREF_DIR)  # 添加这行

步骤 4: 替换 should_skip_channel_line() 方法（第 1543-1556 行）：
    def should_skip_channel_line(
        self, key: str, index: int, url: str
    ) -> bool:
        return self.rules_manager.should_skip(key, index)

步骤 5: （可选）添加规则管理对话框和快捷键

完成！现在规则可以通过 channel_rules.json 配置，无需修改代码。
"""

if __name__ == "__main__":
    print(__doc__)
