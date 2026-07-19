#!/usr/bin/env python3
import sys, re, os, json, threading, time, subprocess, ctypes
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import tkinter as tk
from tkinter import ttk, messagebox
import requests

CONFIG_DIR = Path.home() / ".tv_player"
FAVORITES_FILE = CONFIG_DIR / "favorites.json"
HIDDEN_FILE = CONFIG_DIR / "hidden.json"
CACHE_FILE = CONFIG_DIR / "channels_cache.json"

DEFAULT_SOURCES = [
    {"name": "best-fan", "url": "https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8"},
    {"name": "TVBox", "url": "https://ghfast.top/raw.githubusercontent.com/Supprise0901/TVBox_live/main/live.txt"},
    {"name": "vbskycn", "url": "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/tv.m3u"},
    {"name": "fanmingming", "url": "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"},
]

MIRROR_PREFIXES = [
    "https://ghfast.top/raw.githubusercontent.com/",
    "https://raw.gitmirror.com/",
    "https://raw.kkgithub.com/",
]

HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
TIMEOUT = 8

DWMWA_USE_IMMERSIVE_DARK_MODE = 20
DWMWA_SYSTEMBACKDROP_TYPE = 38
DWMWA_MICA_EFFECT = 1029

user32 = ctypes.windll.user32
dwmapi = ctypes.windll.dwmapi

class Channel:
    def __init__(self, name, url, group=""):
        self.name = name
        self.url = url
        self.group = group

class M3UParser:
    @staticmethod
    def parse(text):
        channels = []
        lines = text.strip().splitlines()
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("#EXTINF:"):
                group_match = re.search(r'group-title="([^"]*)"', line)
                group = group_match.group(1) if group_match else "未分组"
                name_match = re.search(r",(.+?)$", line)
                name = name_match.group(1).strip() if name_match else "未知"
                j = i + 1
                while j < len(lines):
                    nxt = lines[j].strip()
                    if nxt and not nxt.startswith("#"):
                        channels.append(Channel(name, nxt, group))
                        break
                    j += 1
                i = j + 1
            else:
                i += 1
        return channels

class CacheManager:
    def __init__(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    def load(self):
        try:
            if CACHE_FILE.exists():
                data = json.loads(CACHE_FILE.read_text(encoding="utf-8"))
                if data:
                    return [Channel(c["name"], c["url"], c["group"]) for c in data]
        except:
            pass
        return []

    def save(self, channels):
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            data = [{"name": c.name, "url": c.url, "group": c.group} for c in channels]
            CACHE_FILE.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        except:
            pass

class SourceLoader(threading.Thread):
    def __init__(self, sources):
        super().__init__()
        self.sources = sources
        self.channels = []
        self._running = True

    def run(self):
        all_channels = []
        def fetch_one(src):
            for url in self._with_mirrors(src["url"]):
                try:
                    resp = requests.get(url, headers=HEADERS, timeout=TIMEOUT)
                    resp.raise_for_status()
                    return M3UParser.parse(resp.text)
                except:
                    continue
            return []

        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = {pool.submit(fetch_one, src): src for src in self.sources}
            for fut in as_completed(futures):
                try:
                    chs = fut.result(timeout=15)
                    if chs:
                        all_channels.extend(chs)
                except:
                    pass

        if all_channels:
            seen, uniq = set(), []
            for c in all_channels:
                if c.url not in seen:
                    seen.add(c.url)
                    uniq.append(c)
            self.channels = uniq

    def stop(self):
        self._running = False

    def _with_mirrors(self, url):
        urls = [url]
        for prefix in MIRROR_PREFIXES:
            if "raw.githubusercontent.com" in url:
                urls.append(url.replace("https://raw.githubusercontent.com/", prefix))
        return urls

class FavoritesManager:
    def __init__(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        self.favorites = self._load()

    def _load(self):
        try:
            if FAVORITES_FILE.exists():
                return json.loads(FAVORITES_FILE.read_text(encoding="utf-8"))
        except:
            pass
        return []

    def _save(self):
        FAVORITES_FILE.write_text(json.dumps(self.favorites, ensure_ascii=False), encoding="utf-8")

    def add(self, ch):
        if ch.url not in [f["url"] for f in self.favorites]:
            self.favorites.append({"name": ch.name, "url": ch.url, "group": ch.group})
            self._save()
            return True
        return False

    def remove(self, url):
        self.favorites = [f for f in self.favorites if f["url"] != url]
        self._save()

    def is_favorite(self, url):
        return url in [f["url"] for f in self.favorites]

class HiddenManager:
    def __init__(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        self.hidden = set(self._load())

    def _load(self):
        try:
            if HIDDEN_FILE.exists():
                return json.loads(HIDDEN_FILE.read_text(encoding="utf-8"))
        except:
            pass
        return []

    def _save(self):
        HIDDEN_FILE.write_text(json.dumps(list(self.hidden)), encoding="utf-8")

    def hide(self, url):
        self.hidden.add(url)
        self._save()

    def hide_batch(self, urls):
        self.hidden.update(urls)
        self._save()

    def show(self, url):
        self.hidden.discard(url)
        self._save()

    def is_hidden(self, url):
        return url in self.hidden

class TVPlayerApp:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("TV Player")
        self.root.geometry("1000x620")
        self.root.configure(bg="#000000")

        self.channels = []
        self.filtered_channels = []
        self.fav_mgr = FavoritesManager()
        self.hidden_mgr = HiddenManager()
        self.cache_mgr = CacheManager()
        self._mpv_process = None
        self._volume = 100
        self._current_url = None
        self._loading = False
        self._select_mode = False
        self._panel_visible = True
        self._float_btn_win = None

        self._find_mpv()
        self._setup_ui()
        self.root.after(100, self._apply_dark_titlebar)
        self.root.after(300, self._load_cache)

    def _apply_dark_titlebar(self):
        try:
            self.root.update_idletasks()
            hwnd = user32.GetParent(self.root.winfo_id())

            val = ctypes.c_int(1)
            dwmapi.DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
                                         ctypes.byref(val), ctypes.sizeof(val))

            val2 = ctypes.c_int(2)
            dwmapi.DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE,
                                         ctypes.byref(val2), ctypes.sizeof(val2))
        except:
            pass

    def _find_mpv(self):
        mpv_paths = [
            r"C:\Users\96335\mpv\mpv.exe",
            "mpv",
            r"C:\mpv\mpv.exe",
        ]
        self._mpv_path = None
        for path in mpv_paths:
            try:
                result = subprocess.run([path, "--version"], capture_output=True, timeout=3)
                if result.returncode == 0:
                    self._mpv_path = path
                    break
            except:
                continue

    def _setup_ui(self):
        style = ttk.Style()
        style.theme_use('clam')
        style.configure(".", background="#000000", foreground="#e0e0e0")
        style.configure("TFrame", background="#000000")
        style.configure("TLabel", background="#000000", foreground="#e0e0e0")
        style.configure("TButton", background="#0e639c", foreground="white")

        self.left_frame = tk.Frame(self.root, bg="#1E1E1E", width=260)
        self.left_frame.pack(side=tk.LEFT, fill=tk.Y)
        self.left_frame.pack_propagate(False)

        self.toggle_btn = tk.Button(self.left_frame, text="隐藏面板 ▶", bg="#000000", fg="#e0e0e0",
                                   activebackground="#333333", activeforeground="white",
                                   relief=tk.FLAT, font=("", 10), bd=0,
                                   command=self._toggle_panel)
        self.toggle_btn.pack(fill=tk.X, pady=(0, 4))

        self.search_var = tk.StringVar()
        self.search_var.trace("w", lambda *a: self._filter())
        tk.Entry(self.left_frame, textvariable=self.search_var, bg="#1E1E1E", fg="#e0e0e0",
                 insertbackground="#e0e0e0", font=("", 12)).pack(fill=tk.X, pady=(0, 4))

        ctrl_frame = tk.Frame(self.left_frame, bg="#1E1E1E")
        ctrl_frame.pack(fill=tk.X, pady=(0, 4))

        self.group_var = tk.StringVar(value="全部")
        self.group_combo = ttk.Combobox(ctrl_frame, textvariable=self.group_var, values=["全部"], width=15)
        self.group_combo.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.group_combo.bind("<<ComboboxSelected>>", lambda *a: self._filter())

        self.fav_btn = tk.Button(ctrl_frame, text="收藏", bg="#0e639c", fg="white",
                                activebackground="#1177bb", activeforeground="white",
                                relief=tk.FLAT, command=self._toggle_fav)
        self.fav_btn.pack(side=tk.RIGHT, padx=(4, 0))

        list_frame = tk.Frame(self.left_frame, bg="#1E1E1E")
        list_frame.pack(fill=tk.BOTH, expand=True)

        self.channel_list = tk.Listbox(list_frame, bg="#1E1E1E", fg="#e0e0e0",
                                       selectbackground="#094771", selectforeground="white",
                                       font=("", 11), relief=tk.FLAT, highlightthickness=0)
        scrollbar = tk.Scrollbar(list_frame, command=self.channel_list.yview)
        self.channel_list.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.channel_list.pack(fill=tk.BOTH, expand=True)
        self.channel_list.bind("<<ListboxSelect>>", self._on_select)
        self.channel_list.bind("<Button-3>", self._ctx_menu)

        btn_frame = tk.Frame(self.left_frame, bg="#1E1E1E")
        btn_frame.pack(fill=tk.X, pady=(4, 0))
        tk.Button(btn_frame, text="刷新", bg="#0e639c", fg="white", activebackground="#1177bb",
                 relief=tk.FLAT, command=self._refresh).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 2))
        tk.Button(btn_frame, text="换源", bg="#0e639c", fg="white", activebackground="#1177bb",
                 relief=tk.FLAT, command=self._switch_source).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(2, 0))

        batch_frame = tk.Frame(self.left_frame, bg="#1E1E1E")
        batch_frame.pack(fill=tk.X, pady=(4, 0))
        self.select_btn = tk.Button(batch_frame, text="批量选择", bg="#0e639c", fg="white",
                                   activebackground="#1177bb", relief=tk.FLAT, command=self._toggle_select)
        self.select_btn.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 2))
        self.batch_hide_btn = tk.Button(batch_frame, text="隐藏选中", bg="#c0392b", fg="white",
                                       activebackground="#e74c3c", relief=tk.FLAT,
                                       command=self._batch_hide, state=tk.DISABLED)
        self.batch_hide_btn.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(2, 0))

        tk.Button(self.left_frame, text="恢复隐藏频道", bg="#27ae60", fg="white",
                 activebackground="#2ecc71", relief=tk.FLAT, command=self._unhide).pack(fill=tk.X, pady=(4, 0))

        self.status_label = tk.Label(self.left_frame, text="", bg="#1E1E1E", fg="#888888", font=("", 10))
        self.status_label.pack(fill=tk.X, pady=(4, 0))

        self.video_panel = tk.Canvas(self.root, bg="#000000", highlightthickness=0)
        self.video_panel.pack(side=tk.RIGHT, fill=tk.BOTH, expand=True)

        self.video_panel.bind("<Button-1>", lambda e: self._toggle_pause())

        self.root.bind("<Left>", lambda e: self._change_volume(-15))
        self.root.bind("<Right>", lambda e: self._change_volume(15))
        self.root.bind("<space>", lambda e: self._toggle_pause())
        self.root.bind("<F5>", lambda e: self._refresh())

    def _load_cache(self):
        cached = self.cache_mgr.load()
        if cached:
            self.channels = cached
            groups = sorted(set(ch.group for ch in self.channels))
            self.group_combo["values"] = ["全部"] + groups
            self._filter()
            self.status_label.config(text=f"{len(self.channels)} 个频道 (缓存)")
        else:
            self._refresh()

    def _refresh(self):
        if self._loading:
            return
        self._loading = True
        self.status_label.config(text="加载中...")

        def load():
            loader = SourceLoader(DEFAULT_SOURCES)
            loader.start()
            loader.join()
            self.channels = loader.channels
            if self.channels:
                self.cache_mgr.save(self.channels)
            self.root.after(0, self._on_loaded)

        threading.Thread(target=load, daemon=True).start()

    def _on_loaded(self):
        self._loading = False
        groups = sorted(set(ch.group for ch in self.channels))
        self.group_combo["values"] = ["全部"] + groups
        self._filter()
        if self.channels:
            self.status_label.config(text=f"{len(self.channels)} 个频道")
        else:
            self.status_label.config(text="加载失败")

    def _switch_source(self):
        if self._loading:
            return
        self._src_idx = (getattr(self, '_src_idx', 0) + 1) % len(DEFAULT_SOURCES)
        src = DEFAULT_SOURCES[self._src_idx]
        self._loading = True
        self.status_label.config(text=f"切换 {src['name']}...")

        def load():
            loader = SourceLoader([src])
            loader.start()
            loader.join()
            if loader.channels:
                self.channels = loader.channels
                self.cache_mgr.save(self.channels)
            self.root.after(0, self._on_loaded)

        threading.Thread(target=load, daemon=True).start()

    def _filter(self):
        kw = self.search_var.get().lower()
        group = self.group_var.get()
        result = []
        for ch in self.channels:
            if self.hidden_mgr.is_hidden(ch.url):
                continue
            if group != "全部" and ch.group != group:
                continue
            if kw and kw not in ch.name.lower():
                continue
            result.append(ch)
        self.filtered_channels = result
        self.channel_list.delete(0, tk.END)
        for ch in result:
            prefix = "★ " if self.fav_mgr.is_favorite(ch.url) else "▸ "
            self.channel_list.insert(tk.END, f"{prefix}{ch.name}")

    def _on_select(self, event):
        if self._select_mode:
            return
        selection = self.channel_list.curselection()
        if not selection:
            return
        idx = selection[0]
        if 0 <= idx < len(self.filtered_channels):
            ch = self.filtered_channels[idx]
            self._play(ch.url)

    def _play(self, url):
        if url == self._current_url:
            return
        self._current_url = url
        self.stop_mpv()

        if not self._mpv_path:
            self.status_label.config(text="未找到mpv播放器")
            return

        self.video_panel.update_idletasks()
        wid = self.video_panel.winfo_id()

        cmd = [
            self._mpv_path,
            f"--wid={wid}",
            "--no-terminal",
            "--no-osd-bar",
            "--cache=yes",
            "--cache-secs=2",
            "--demuxer-max-bytes=50MiB",
            f"--volume={self._volume}",
            url
        ]

        self._mpv_process = subprocess.Popen(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )

    def stop_mpv(self):
        if self._mpv_process:
            try:
                self._mpv_process.terminate()
                self._mpv_process.wait(timeout=2)
            except:
                try:
                    self._mpv_process.kill()
                except:
                    pass
            self._mpv_process = None

    def _toggle_pause(self):
        if self._mpv_process and self._mpv_process.poll() is None:
            try:
                self._mpv_process.stdin.write(b"cycle pause\n")
                self._mpv_process.stdin.flush()
            except:
                pass

    def _change_volume(self, delta):
        self._volume = max(0, min(100, self._volume + delta))
        if self._mpv_process and self._mpv_process.poll() is None:
            try:
                self._mpv_process.stdin.write(f"set volume {self._volume}\n".encode())
                self._mpv_process.stdin.flush()
            except:
                pass
        self.status_label.config(text=f"音量: {self._volume}")

    def _toggle_fav(self):
        self._show_fav = not getattr(self, '_show_fav', False)
        self.fav_btn.config(text="全部" if self._show_fav else "收藏")
        if getattr(self, '_show_fav', False):
            fav_urls = {f["url"] for f in self.fav_mgr.favorites}
            self.filtered_channels = [ch for ch in self.channels if ch.url in fav_urls]
            self.channel_list.delete(0, tk.END)
            for ch in self.filtered_channels:
                prefix = "★ " if self.fav_mgr.is_favorite(ch.url) else "▸ "
                self.channel_list.insert(tk.END, f"{prefix}{ch.name}")
        else:
            self._filter()

    def _toggle_select(self):
        self._select_mode = not self._select_mode
        self.select_btn.config(text="退出选择" if self._select_mode else "批量选择")
        self.batch_hide_btn.config(state=tk.NORMAL if self._select_mode else tk.DISABLED)
        if not self._select_mode:
            self.channel_list.selection_clear(0, tk.END)

    def _batch_hide(self):
        selection = self.channel_list.curselection()
        if not selection:
            return
        urls = [self.filtered_channels[i].url for i in selection if i < len(self.filtered_channels)]
        if urls and messagebox.askyesno("确认", f"隐藏 {len(urls)} 个频道?"):
            self.hidden_mgr.hide_batch(urls)
            self._filter()

    def _unhide(self):
        hidden = list(self.hidden_mgr.hidden)
        if not hidden:
            messagebox.showinfo("提示", "没有隐藏的频道")
            return

        hidden_chs = [ch for ch in self.channels if ch.url in hidden]

        dialog = tk.Toplevel(self.root)
        dialog.title("恢复隐藏频道")
        dialog.geometry("400x400")
        dialog.configure(bg="#1E1E1E")
        dialog.transient(self.root)
        dialog.grab_set()

        tk.Label(dialog, text=f"共 {len(hidden_chs)} 个隐藏频道，勾选要恢复的:",
                bg="#1E1E1E", fg="#aaaaaa", font=("", 10)).pack(pady=5)

        canvas = tk.Canvas(dialog, bg="#1E1E1E", highlightthickness=0)
        scrollbar = tk.Scrollbar(dialog, command=canvas.yview)
        scrollable = tk.Frame(canvas, bg="#1E1E1E")
        scrollable.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.create_window((0, 0), window=scrollable, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)

        vars_list = []
        for ch in hidden_chs:
            var = tk.BooleanVar()
            tk.Checkbutton(scrollable, text=ch.name, variable=var,
                          bg="#1E1E1E", fg="#e0e0e0", selectcolor="#1E1E1E",
                          activebackground="#1E1E1E", activeforeground="#e0e0e0",
                          font=("", 11)).pack(anchor=tk.W, padx=5)
            vars_list.append((var, ch.url))

        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        btn_frame = tk.Frame(dialog, bg="#1E1E1E")
        btn_frame.pack(fill=tk.X, pady=5)
        tk.Button(btn_frame, text="全选", bg="#0e639c", fg="white",
                 command=lambda: [v.set(True) for v, _ in vars_list]).pack(side=tk.LEFT, padx=2)
        tk.Button(btn_frame, text="全不选", bg="#0e639c", fg="white",
                 command=lambda: [v.set(False) for v, _ in vars_list]).pack(side=tk.LEFT, padx=2)

        def confirm():
            urls = [url for var, url in vars_list if var.get()]
            for url in urls:
                self.hidden_mgr.show(url)
            dialog.destroy()
            self._filter()

        tk.Button(btn_frame, text="恢复选中", bg="#27ae60", fg="white", command=confirm).pack(side=tk.RIGHT, padx=2)
        tk.Button(btn_frame, text="取消", bg="#555555", fg="white", command=dialog.destroy).pack(side=tk.RIGHT, padx=2)

    def _ctx_menu(self, event):
        try:
            idx = self.channel_list.nearest(event.y)
            if idx < 0 or idx >= len(self.filtered_channels):
                return
            ch = self.filtered_channels[idx]

            menu = tk.Menu(self.root, tearoff=0, bg="#2d2d2d", fg="#e0e0e0",
                          activebackground="#094771", activeforeground="white")

            if self.fav_mgr.is_favorite(ch.url):
                menu.add_command(label="取消收藏", command=lambda: (self.fav_mgr.remove(ch.url), self._filter()))
            else:
                menu.add_command(label="添加收藏", command=lambda: (self.fav_mgr.add(ch), self._filter()))
            menu.add_separator()
            menu.add_command(label="复制地址", command=lambda: (self.root.clipboard_clear(),
                             self.root.clipboard_append(ch.url), self.status_label.config(text="已复制")))
            menu.add_separator()
            menu.add_command(label="隐藏频道", command=lambda: (self.hidden_mgr.hide(ch.url), self._filter()))
            menu.post(event.x_root, event.y_root)
        except:
            pass

    def _toggle_panel(self):
        self._panel_visible = not self._panel_visible
        if self._panel_visible:
            self._hide_float_btn()
            self.left_frame.pack(side=tk.LEFT, fill=tk.Y)
            self.toggle_btn.config(text="隐藏面板 ▶")
        else:
            self.left_frame.pack_forget()
            self.toggle_btn.config(text="◀ 显示面板")
            self._show_float_btn()

    def _show_float_btn(self):
        if self._float_btn_win:
            return
        self._float_btn_win = tk.Toplevel(self.root)
        self._float_btn_win.overrideredirect(True)
        self._float_btn_win.attributes("-topmost", True)
        self._float_btn_win.configure(bg="#000000")
        btn = tk.Button(self._float_btn_win, text="▶", bg="#000000", fg="#e0e0e0",
                       activebackground="#333333", activeforeground="white",
                       relief=tk.FLAT, font=("", 14), bd=0,
                       command=self._toggle_panel)
        btn.pack(padx=2, pady=2)
        self._update_float_pos()
        self._check_window_state()

    def _check_window_state(self):
        if not self._float_btn_win:
            return
        try:
            state = self.root.wm_state()
            if state == "iconic":
                self._float_btn_win.withdraw()
            else:
                if self._float_btn_win.winfo_viewable() == 0 and not self._panel_visible:
                    self._float_btn_win.deiconify()
                    self._update_float_pos()
        except:
            pass
        self.root.after(100, self._check_window_state)

    def _update_float_pos(self):
        if not self._float_btn_win:
            return
        self.root.update_idletasks()
        x = self.root.winfo_rootx()
        y = self.root.winfo_rooty()
        self._float_btn_win.geometry(f"40x40+{x}+{y}")

    def _hide_float_btn(self):
        if self._float_btn_win:
            self._float_btn_win.destroy()
            self._float_btn_win = None

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.mainloop()

    def _on_close(self):
        self.stop_mpv()
        self._hide_float_btn()
        self.root.destroy()

if __name__ == "__main__":
    app = TVPlayerApp()
    app.run()
