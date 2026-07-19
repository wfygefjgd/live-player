"""Python电视直播软件"""
import sys
import os

# 尝试导入customtkinter，如果失败则使用tkinter
try:
    import customtkinter as ctk
    HAS_CUSTOMTKINTER = True
except ImportError:
    import tkinter as tk
    from tkinter import ttk
    HAS_CUSTOMTKINTER = False

import tkinter.messagebox as messagebox
import threading
from channel_manager import ChannelManager, Channel


class TVPlayer:
    """电视播放器主界面"""
    
    def __init__(self):
        self.channel_manager = ChannelManager()
        self.current_channel = None
        self.is_playing = False
        
        if HAS_CUSTOMTKINTER:
            self.setup_customtkinter_gui()
        else:
            self.setup_tkinter_gui()
    
    def setup_customtkinter_gui(self):
        """使用customtkinter设置GUI"""
        ctk.set_appearance_mode("dark")
        ctk.set_default_color_theme("blue")
        
        self.root = ctk.CTk()
        self.root.title("Python TV Player - 电视直播")
        self.root.geometry("1000x700")
        self.root.minsize(800, 600)
        
        # 主框架
        main_frame = ctk.CTkFrame(self.root)
        main_frame.pack(fill="both", expand=True, padx=10, pady=10)
        
        # 顶部控制栏
        top_frame = ctk.CTkFrame(main_frame)
        top_frame.pack(fill="x", padx=10, pady=(10, 5))
        
        self.title_label = ctk.CTkLabel(top_frame, text="Python TV Player", font=("", 24, "bold"))
        self.title_label.pack(side="left", padx=10)
        
        # 刷新按钮
        refresh_btn = ctk.CTkButton(top_frame, text="刷新源", command=self.refresh_channels, width=100)
        refresh_btn.pack(side="right", padx=5)
        
        # 切换源按钮
        switch_btn = ctk.CTkButton(top_frame, text="切换源", command=self.switch_source, width=100)
        switch_btn.pack(side="right", padx=5)
        
        # 中间内容区
        content_frame = ctk.CTkFrame(main_frame)
        content_frame.pack(fill="both", expand=True, padx=10, pady=5)
        
        # 左侧频道列表
        left_frame = ctk.CTkFrame(content_frame, width=300)
        left_frame.pack(side="left", fill="y", padx=(0, 5))
        
        # 搜索框
        self.search_var = ctk.StringVar()
        self.search_var.trace("w", self.filter_channels)
        search_entry = ctk.CTkEntry(left_frame, textvariable=self.search_var, placeholder_text="搜索频道...")
        search_entry.pack(fill="x", padx=5, pady=5)
        
        # 分组选择
        group_frame = ctk.CTkFrame(left_frame)
        group_frame.pack(fill="x", padx=5, pady=5)
        
        ctk.CTkLabel(group_frame, text="分组:").pack(side="left", padx=5)
        self.group_var = ctk.StringVar(value="全部")
        self.group_combo = ctk.CTkComboBox(
            group_frame, 
            values=["全部"], 
            variable=self.group_var,
            command=self.on_group_change,
            width=200
        )
        self.group_combo.pack(side="left", fill="x", expand=True)
        
        # 频道列表
        list_frame = ctk.CTkFrame(left_frame)
        list_frame.pack(fill="both", expand=True, padx=5, pady=5)
        
        self.channel_listbox = ctk.CTkTextbox(list_frame, state="disabled")
        self.channel_listbox.pack(fill="both", expand=True)
        
        # 绑定点击事件
        self.channel_listbox.bind("<Button-1>", self.on_channel_click)
        
        # 右侧播放区
        right_frame = ctk.CTkFrame(content_frame)
        right_frame.pack(side="right", fill="both", expand=True)
        
        # 播放信息
        self.play_info_label = ctk.CTkLabel(right_frame, text="请选择频道开始播放", font=("", 16))
        self.play_info_label.pack(pady=20)
        
        # 播放状态
        self.status_label = ctk.CTkLabel(right_frame, text="就绪", font=("", 12))
        self.status_label.pack(pady=10)
        
        # 播放控制按钮
        control_frame = ctk.CTkFrame(right_frame)
        control_frame.pack(pady=20)
        
        self.play_btn = ctk.CTkButton(control_frame, text="播放", command=self.play_selected_channel, width=100)
        self.play_btn.pack(side="left", padx=10)
        
        self.stop_btn = ctk.CTkButton(control_frame, text="停止", command=self.stop_playback, width=100)
        self.stop_btn.pack(side="left", padx=10)
        
        # 底部状态栏
        bottom_frame = ctk.CTkFrame(main_frame)
        bottom_frame.pack(fill="x", padx=10, pady=(5, 10))
        
        self.channel_count_label = ctk.CTkLabel(bottom_frame, text="频道数: 0")
        self.channel_count_label.pack(side="left", padx=10)
        
        self.source_label = ctk.CTkLabel(bottom_frame, text="当前源: 默认")
        self.source_label.pack(side="right", padx=10)
        
        # 绑定关闭事件
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)
        
    def setup_tkinter_gui(self):
        """使用原生tkinter设置GUI"""
        self.root = tk.Tk()
        self.root.title("Python TV Player - 电视直播")
        self.root.geometry("1000x700")
        self.root.minsize(800, 600)
        self.root.configure(bg="#1a1a2e")
        
        # 样式
        style = ttk.Style()
        style.theme_use('clam')
        
        # 主框架
        main_frame = tk.Frame(self.root, bg="#1a1a2e")
        main_frame.pack(fill="both", expand=True, padx=10, pady=10)
        
        # 顶部控制栏
        top_frame = tk.Frame(main_frame, bg="#16213e")
        top_frame.pack(fill="x", padx=10, pady=(10, 5))
        
        self.title_label = tk.Label(top_frame, text="Python TV Player", 
                                   font=("", 24, "bold"), bg="#16213e", fg="white")
        self.title_label.pack(side="left", padx=10)
        
        # 刷新按钮
        refresh_btn = tk.Button(top_frame, text="刷新源", command=self.refresh_channels,
                               bg="#0f3460", fg="white", width=10)
        refresh_btn.pack(side="right", padx=5)
        
        # 切换源按钮
        switch_btn = tk.Button(top_frame, text="切换源", command=self.switch_source,
                              bg="#0f3460", fg="white", width=10)
        switch_btn.pack(side="right", padx=5)
        
        # 中间内容区
        content_frame = tk.Frame(main_frame, bg="#1a1a2e")
        content_frame.pack(fill="both", expand=True, padx=10, pady=5)
        
        # 左侧频道列表
        left_frame = tk.Frame(content_frame, bg="#16213e", width=300)
        left_frame.pack(side="left", fill="y", padx=(0, 5))
        
        # 搜索框
        self.search_var = tk.StringVar()
        self.search_var.trace("w", self.filter_channels)
        search_entry = tk.Entry(left_frame, textvariable=self.search_var, bg="#0f3460", fg="white")
        search_entry.pack(fill="x", padx=5, pady=5)
        
        # 分组选择
        group_frame = tk.Frame(left_frame, bg="#16213e")
        group_frame.pack(fill="x", padx=5, pady=5)
        
        tk.Label(group_frame, text="分组:", bg="#16213e", fg="white").pack(side="left", padx=5)
        self.group_var = tk.StringVar(value="全部")
        self.group_combo = ttk.Combobox(group_frame, textvariable=self.group_var, values=["全部"], width=20)
        self.group_combo.pack(side="left", fill="x", expand=True)
        self.group_combo.bind("<<ComboboxSelected>>", self.on_group_change)
        
        # 频道列表
        list_frame = tk.Frame(left_frame, bg="#16213e")
        list_frame.pack(fill="both", expand=True, padx=5, pady=5)
        
        self.channel_listbox = tk.Listbox(list_frame, bg="#0f3460", fg="white", 
                                         selectbackground="#e94560", selectforeground="white",
                                         font=("", 11))
        self.channel_listbox.pack(fill="both", expand=True)
        self.channel_listbox.bind("<Button-1>", self.on_channel_click)
        
        # 右侧播放区
        right_frame = tk.Frame(content_frame, bg="#16213e")
        right_frame.pack(side="right", fill="both", expand=True)
        
        # 播放信息
        self.play_info_label = tk.Label(right_frame, text="请选择频道开始播放", 
                                       font=("", 16), bg="#16213e", fg="white")
        self.play_info_label.pack(pady=20)
        
        # 播放状态
        self.status_label = tk.Label(right_frame, text="就绪", font=("", 12), 
                                    bg="#16213e", fg="#aaaaaa")
        self.status_label.pack(pady=10)
        
        # 播放控制按钮
        control_frame = tk.Frame(right_frame, bg="#16213e")
        control_frame.pack(pady=20)
        
        self.play_btn = tk.Button(control_frame, text="播放", command=self.play_selected_channel,
                                 bg="#e94560", fg="white", width=10)
        self.play_btn.pack(side="left", padx=10)
        
        self.stop_btn = tk.Button(control_frame, text="停止", command=self.stop_playback,
                                 bg="#0f3460", fg="white", width=10)
        self.stop_btn.pack(side="left", padx=10)
        
        # 底部状态栏
        bottom_frame = tk.Frame(main_frame, bg="#16213e")
        bottom_frame.pack(fill="x", padx=10, pady=(5, 10))
        
        self.channel_count_label = tk.Label(bottom_frame, text="频道数: 0", 
                                           bg="#16213e", fg="white")
        self.channel_count_label.pack(side="left", padx=10)
        
        self.source_label = tk.Label(bottom_frame, text="当前源: 默认", 
                                    bg="#16213e", fg="white")
        self.source_label.pack(side="right", padx=10)
        
        # 绑定关闭事件
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)
    
    def load_channels(self):
        """加载频道列表"""
        self.status_label.configure(text="正在加载频道...")
        self.root.update()
        
        def load_in_thread():
            success = self.channel_manager.fetch_source()
            self.root.after(0, lambda: self.on_channels_loaded(success))
        
        thread = threading.Thread(target=load_in_thread, daemon=True)
        thread.start()
    
    def on_channels_loaded(self, success: bool):
        """频道加载完成回调"""
        if success:
            self.update_channel_list()
            self.update_group_list()
            self.channel_count_label.configure(text=f"频道数: {len(self.channel_manager.channels)}")
            self.status_label.configure(text="频道加载完成")
        else:
            self.status_label.configure(text="频道加载失败")
            messagebox.showerror("错误", "无法加载直播源，请检查网络连接")
    
    def update_channel_list(self, channels=None):
        """更新频道列表显示"""
        if channels is None:
            channels = self.channel_manager.channels
        
        if HAS_CUSTOMTKINTER:
            self.channel_listbox.configure(state="normal")
            self.channel_listbox.delete("1.0", "end")
            for ch in channels:
                self.channel_listbox.insert("end", f"📺 {ch.name}\n")
            self.channel_listbox.configure(state="disabled")
        else:
            self.channel_listbox.delete(0, "end")
            for ch in channels:
                self.channel_listbox.insert("end", f"📺 {ch.name}")
    
    def update_group_list(self):
        """更新分组列表"""
        groups = ["全部"] + self.channel_manager.get_all_groups()
        if HAS_CUSTOMTKINTER:
            self.group_combo.configure(values=groups)
        else:
            self.group_combo['values'] = groups
    
    def filter_channels(self, *args):
        """根据搜索框过滤频道"""
        search_text = self.search_var.get().lower()
        group = self.group_var.get()
        
        filtered = []
        for ch in self.channel_manager.channels:
            # 分组过滤
            if group != "全部" and ch.group != group:
                continue
            # 搜索过滤
            if search_text and search_text not in ch.name.lower():
                continue
            filtered.append(ch)
        
        self.update_channel_list(filtered)
    
    def on_group_change(self, *args):
        """分组切换回调"""
        self.filter_channels()
    
    def on_channel_click(self, event):
        """频道点击事件"""
        if HAS_CUSTOMTKINTER:
            # 获取点击位置
            index = self.channel_listbox.index("@{},{}".format(event.x, event.y))
            line_num = int(index.split(".")[0]) - 1
        else:
            selection = self.channel_listbox.curselection()
            if selection:
                line_num = selection[0]
            else:
                return
        
        # 获取当前显示的频道列表
        search_text = self.search_var.get().lower()
        group = self.group_var.get()
        
        filtered = []
        for ch in self.channel_manager.channels:
            if group != "全部" and ch.group != group:
                continue
            if search_text and search_text not in ch.name.lower():
                continue
            filtered.append(ch)
        
        if 0 <= line_num < len(filtered):
            self.current_channel = filtered[line_num]
            self.play_info_label.configure(text=f"当前频道: {self.current_channel.name}")
    
    def play_selected_channel(self):
        """播放选中的频道"""
        if not self.current_channel:
            messagebox.showwarning("提示", "请先选择一个频道")
            return
        
        self.play_info_label.configure(text=f"正在播放: {self.current_channel.name}")
        self.status_label.configure(text=f"播放地址: {self.current_channel.url}")
        
        # 这里可以集成VLC播放器
        # 由于需要安装VLC，这里提供一个简单的演示
        self.show_play_info()
    
    def show_play_info(self):
        """显示播放信息（在没有VLC的情况下）"""
        if self.current_channel:
            info = f"""频道: {self.current_channel.name}
分组: {self.current_channel.group}
播放地址: {self.current_channel.url}

请复制播放地址到支持M3U8的播放器中播放:
- VLC Media Player
- PotPlayer
- mpv
- 或其他支持HLS的播放器"""
            
            if HAS_CUSTOMTKINTER:
                # 创建新窗口显示信息
                info_window = ctk.CTkToplevel(self.root)
                info_window.title("播放信息")
                info_window.geometry("600x400")
                
                text_box = ctk.CTkTextbox(info_window, wrap="word")
                text_box.pack(fill="both", expand=True, padx=10, pady=10)
                text_box.insert("1.0", info)
                text_box.configure(state="disabled")
            else:
                messagebox.showinfo("播放信息", info)
    
    def stop_playback(self):
        """停止播放"""
        self.current_channel = None
        self.play_info_label.configure(text="请选择频道开始播放")
        self.status_label.configure(text="已停止播放")
    
    def refresh_channels(self):
        """刷新频道"""
        self.load_channels()
    
    def switch_source(self):
        """切换直播源"""
        if self.channel_manager.switch_source():
            self.update_channel_list()
            self.update_group_list()
            self.channel_count_label.configure(text=f"频道数: {len(self.channel_manager.channels)}")
            self.source_label.configure(text=f"当前源: 第{self.channel_manager.current_source_index + 1}个")
            self.status_label.configure(text="源切换成功")
        else:
            messagebox.showerror("错误", "无法切换直播源")
    
    def on_closing(self):
        """关闭窗口"""
        self.root.destroy()
    
    def run(self):
        """运行程序"""
        self.load_channels()
        self.root.mainloop()


def main():
    """主函数"""
    print("正在启动 Python TV Player...")
    print("提示: 建议安装 customtkinter 以获得更好的界面体验")
    print("安装命令: pip install customtkinter")
    print("-" * 50)
    
    app = TVPlayer()
    app.run()


if __name__ == "__main__":
    main()
