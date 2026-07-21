#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TV Player 桌面版 — 对齐 Android 原生 (android-native)"""
from __future__ import annotations

import ctypes
import json
import os
import re
import subprocess
import threading
import uuid
from collections import OrderedDict
from pathlib import Path

import tkinter as tk
from tkinter import messagebox

try:
    import requests
except ImportError:
    raise SystemExit("请先安装: pip install requests")

# ---------------------------------------------------------------------------
# 路径 / 常量（与 Android MainActivity 一致）
# ---------------------------------------------------------------------------
CONFIG_DIR = Path.home() / ".tv_player"
CONFIG_DIR.mkdir(parents=True, exist_ok=True)

CACHE_FILE = CONFIG_DIR / "channels_cache.json"
SOURCE_URLS_FILE = CONFIG_DIR / "source_urls.json"
SELECTED_SOURCE_FILE = CONFIG_DIR / "selected_source.json"
HIDDEN_LINES_FILE = CONFIG_DIR / "hidden_lines.json"
FAVORITES_FILE = CONFIG_DIR / "favorites.json"
HIDDEN_CHANNELS_FILE = CONFIG_DIR / "hidden.json"

# Android DEFAULT_SOURCE_URL + DEFAULT_MIRRORS
DEFAULT_SOURCE_URL = (
    "https://raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8"
)

# 预置源列表（Android 默认 + 桌面历史常用源，源管理里可切换）
PRESET_SOURCES = [
    {
        "name": "默认源 (best-fan 状态检测)",
        "url": DEFAULT_SOURCE_URL,
        "builtin": True,
    },
    {
        "name": "best-fan 全量",
        "url": "https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8",
        "builtin": True,
    },
    {
        "name": "TVBox",
        "url": "https://ghfast.top/raw.githubusercontent.com/Supprise0901/TVBox_live/main/live.txt",
        "builtin": True,
    },
    {
        "name": "vbskycn",
        "url": "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/tv.m3u",
        "builtin": True,
    },
    {
        "name": "fanmingming IPv6",
        "url": "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u",
        "builtin": True,
    },
]

DEFAULT_MIRRORS = [
    DEFAULT_SOURCE_URL,
    "https://ghfast.top/raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
    "https://raw.gitmirror.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
    "https://raw.kkgithub.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
]

MIRROR_PREFIXES = [
    "https://ghfast.top/raw.githubusercontent.com/",
    "https://raw.gitmirror.com/",
    "https://raw.kkgithub.com/",
]

HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
HTTP_TIMEOUT = 12
CHANNEL_OSD_MS = 2500
CHANNEL_SWITCH_TIMEOUT_MS = 7000
STALL_TIMEOUT_MS = 7000
FLOAT_HIDE_MS = 2500

MPV_CANDIDATES = [
    Path.home() / "mpv" / "mpv.exe",
    Path(r"C:\Users\96335\mpv\mpv.exe"),
    Path(r"C:\mpv\mpv.exe"),
    Path(r"C:\Program Files\mpv\mpv.exe"),
    Path("mpv"),
]


# ---------------------------------------------------------------------------
# 数据模型 / 解析（对齐 Android Channel + M3UParser）
# ---------------------------------------------------------------------------
class Channel:
    def __init__(self, name, group="未分组", key=None, urls=None):
        self.name = (name or "未知").strip() or "未知"
        self.group = (group or "未分组").strip() or "未分组"
        self.key = (key or M3UParser.normalize_name(self.name)).strip()
        self.urls: list[str] = []
        if urls:
            for u in urls:
                self.add_url(u)

    def add_url(self, url: str):
        clean = (url or "").strip()
        if clean and clean not in self.urls:
            self.urls.append(clean)

    @property
    def source_count(self) -> int:
        return len(self.urls)


class M3UParser:
    GROUP = re.compile(r'group-title="([^"]*)"')
    NAME = re.compile(r",(.+?)$")
    CCTV = re.compile(r"cctv\s*[-_ ]*0*([1-9]\d*)(k|\+)?", re.I)
    TRAILING = re.compile(
        r"(fhd|uhd|hd|sd|4k|8k|1080p|720p|576p|50fps|60fps|h264|h265|hevc|hdr|"
        r"高清|超清|标清|蓝光|流畅|高码|高帧|测试|备用\d*|线路\d+|源\d+|"
        r"直播|在线|综合|频道|央视|卫视|中文|台)$",
        re.I,
    )

    @classmethod
    def parse(cls, text: str) -> list[Channel]:
        if not text:
            return []
        # 兼容 TVBox live.txt 等 txt 格式
        if "#EXTM3U" not in text and "#EXTINF" not in text:
            return cls._parse_txt(text)

        channels: OrderedDict[str, Channel] = OrderedDict()
        pending_name = None
        pending_group = "未分组"
        for raw in text.splitlines():
            line = raw.strip()
            if line.startswith("#EXTINF:"):
                gm = cls.GROUP.search(line)
                pending_group = gm.group(1) if gm else "未分组"
                nm = cls.NAME.search(line)
                pending_name = nm.group(1).strip() if nm else "未知"
            elif line and not line.startswith("#") and pending_name is not None:
                display = cls.normalize_display_name(pending_name)
                key = cls.normalize_name(display)
                ch = channels.get(key)
                if ch is None:
                    ch = Channel(display, pending_group, key)
                    channels[key] = ch
                ch.add_url(line)
                pending_name = None
                pending_group = "未分组"
        return list(channels.values())

    @classmethod
    def _parse_txt(cls, text: str) -> list[Channel]:
        """TVBox 风格: 分组名,#genre# / 名称,url"""
        channels: OrderedDict[str, Channel] = OrderedDict()
        group = "未分组"
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.endswith("#genre#") or ",#genre#" in line:
                group = line.split(",")[0].strip() or "未分组"
                continue
            if "," not in line:
                continue
            name, url = line.split(",", 1)
            name, url = name.strip(), url.strip()
            if not name or not url or not url.startswith("http"):
                continue
            display = cls.normalize_display_name(name)
            key = cls.normalize_name(display)
            ch = channels.get(key)
            if ch is None:
                ch = Channel(display, group, key)
                channels[key] = ch
            ch.add_url(url)
        return list(channels.values())

    @classmethod
    def normalize_name(cls, name: str) -> str:
        if not name:
            return ""
        working = name.strip().lower()
        m = cls.CCTV.search(working)
        if m:
            suffix = (m.group(2) or "").upper()
            return f"cctv{int(m.group(1))}{suffix}"
        working = re.sub(r"[\s\-—_·.．,，、/\\|()（）\[\]【】:+]+", "", working)
        for a, b in (
            ("中央", "cctv"),
            ("央视", "cctv"),
            ("高清", ""),
            ("超清", ""),
            ("蓝光", ""),
            ("流畅", ""),
            ("频道", ""),
            ("直播", ""),
            ("在线", ""),
        ):
            working = working.replace(a, b)
        working = re.sub(r"(测试|试看|备份|备用|线路|源)+", "", working)
        working = re.sub(r"(?:第)?0*([1-9]\d*)台$", r"\1", working)
        while True:
            m = cls.TRAILING.search(working)
            if not m:
                break
            working = working[: m.start()]
        return working

    @classmethod
    def normalize_display_name(cls, raw_name: str) -> str:
        clean = (raw_name or "未知").strip()
        m = cls.CCTV.search(clean)
        if m:
            suffix = (m.group(2) or "").upper()
            return f"CCTV-{int(m.group(1))}{suffix}"
        clean = re.sub(r"\s+", " ", clean)
        clean = re.sub(
            r"(?i)(高清|超清|蓝光|流畅|频道|直播|在线|测试|备用\d*|线路\d+|源\d+)$",
            "",
            clean,
        ).strip()
        # 去掉 [1080][S] 这类后缀
        clean = re.sub(r"\[[^\]]*\]", "", clean).strip()
        return clean or "未知"


# ---------------------------------------------------------------------------
# 存储（对齐 Android StorageHelper）
# ---------------------------------------------------------------------------
class Storage:
    def _load(self, path: Path, default):
        try:
            if path.exists():
                return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            pass
        return default

    def _save(self, path: Path, data):
        try:
            path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        except Exception:
            pass

    def save_channels(self, channels: list[Channel]):
        data = [
            {"name": c.name, "group": c.group, "key": c.key, "urls": list(c.urls)}
            for c in channels
        ]
        self._save(CACHE_FILE, data)

    def load_channels(self) -> list[Channel]:
        out = []
        for o in self._load(CACHE_FILE, []) or []:
            urls = o.get("urls") or ([o["url"]] if o.get("url") else [])
            out.append(
                Channel(
                    o.get("name", "未知"),
                    o.get("group", "未分组"),
                    o.get("key") or M3UParser.normalize_name(o.get("name", "")),
                    urls,
                )
            )
        return out

    def load_source_urls(self) -> list[str]:
        return [u for u in (self._load(SOURCE_URLS_FILE, []) or []) if u]

    def save_source_urls(self, urls: list[str]):
        seen, clean = set(), []
        for u in urls or []:
            s = (u or "").strip()
            if s and s not in seen:
                seen.add(s)
                clean.append(s)
        self._save(SOURCE_URLS_FILE, clean)

    def load_selected(self) -> str:
        data = self._load(SELECTED_SOURCE_FILE, {})
        if isinstance(data, str):
            return data
        return (data or {}).get("url", "")

    def save_selected(self, url: str):
        self._save(SELECTED_SOURCE_FILE, {"url": (url or "").strip()})

    def load_hidden_lines(self) -> set[str]:
        return set(self._load(HIDDEN_LINES_FILE, []) or [])

    def hide_line(self, url: str):
        if not url:
            return
        s = self.load_hidden_lines()
        s.add(url.strip())
        self._save(HIDDEN_LINES_FILE, list(s))

    def is_line_hidden(self, url: str) -> bool:
        return bool(url) and url.strip() in self.load_hidden_lines()

    def load_favorites(self) -> set[str]:
        return set(self._load(FAVORITES_FILE, []) or [])

    def toggle_favorite(self, key: str) -> bool:
        fav = self.load_favorites()
        if key in fav:
            fav.discard(key)
            self._save(FAVORITES_FILE, list(fav))
            return False
        fav.add(key)
        self._save(FAVORITES_FILE, list(fav))
        return True

    def is_favorite(self, key: str) -> bool:
        return key in self.load_favorites()

    def load_hidden_channels(self) -> set[str]:
        return set(self._load(HIDDEN_CHANNELS_FILE, []) or [])

    def hide_channel(self, key: str):
        h = self.load_hidden_channels()
        h.add(key)
        self._save(HIDDEN_CHANNELS_FILE, list(h))

    def is_channel_hidden(self, key: str) -> bool:
        return key in self.load_hidden_channels()

    def unhide_all_channels(self):
        self._save(HIDDEN_CHANNELS_FILE, [])


def should_skip_channel_line(key: str, index: int) -> bool:
    # 与 Android shouldSkipChannelLine 一致
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


def apply_channel_line_rules(channels: list[Channel], storage: Storage) -> list[Channel]:
    output = []
    for src in channels:
        if not src:
            continue
        filtered = Channel(src.name, src.group, src.key)
        for i, url in enumerate(src.urls):
            if storage.is_line_hidden(url):
                continue
            if should_skip_channel_line(src.key, i):
                continue
            filtered.add_url(url)
        if filtered.source_count > 0 and not storage.is_channel_hidden(filtered.key):
            output.append(filtered)
    return output


def source_display_name(url: str) -> str:
    for p in PRESET_SOURCES:
        if p["url"] == url:
            return p["name"]
    if url == DEFAULT_SOURCE_URL:
        return "默认源 (best-fan 状态检测)"
    if len(url) > 64:
        return url[:61] + "..."
    return url


def find_mpv() -> str | None:
    for p in MPV_CANDIDATES:
        path = str(p)
        try:
            flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
            r = subprocess.run(
                [path, "--version"],
                capture_output=True,
                timeout=3,
                creationflags=flags,
            )
            if r.returncode == 0:
                return path
        except Exception:
            continue
    return None


# ---------------------------------------------------------------------------
# mpv 播放器
# ---------------------------------------------------------------------------
class MpvPlayer:
    def __init__(self, path: str | None):
        self.path = path
        self.proc: subprocess.Popen | None = None
        self.ipc = ""
        self.volume = 80
        self.paused = False

    def play(self, url: str, wid: int) -> bool:
        self.stop()
        if not self.path or not url:
            return False
        name = f"mpv-tv-{uuid.uuid4().hex}"
        self.ipc = rf"\\.\pipe\{name}" if os.name == "nt" else str(CONFIG_DIR / f"{name}.sock")
        cmd = [
            self.path,
            f"--wid={wid}",
            "--no-terminal",
            "--force-window=no",
            "--keep-open=yes",
            "--idle=yes",
            "--cache=yes",
            "--cache-secs=3",
            "--demuxer-max-bytes=50MiB",
            f"--volume={self.volume}",
            f"--input-ipc-server={self.ipc}",
            "--input-default-bindings=no",
            "--osc=no",
            "--osd-level=0",
            url,
        ]
        try:
            kw = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
            if os.name == "nt":
                kw["creationflags"] = subprocess.CREATE_NO_WINDOW
            self.proc = subprocess.Popen(cmd, **kw)
            self.paused = False
            return True
        except Exception:
            self.proc = None
            return False

    def stop(self):
        if self.proc:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None
        self.paused = False

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def _ipc(self, command: dict) -> bool:
        if not self.ipc or not self.alive():
            return False
        payload = (json.dumps(command) + "\n").encode("utf-8")
        if os.name == "nt":
            try:
                GENERIC_WRITE = 0x40000000
                OPEN_EXISTING = 3
                h = ctypes.windll.kernel32.CreateFileW(
                    self.ipc, GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None
                )
                if h in (-1, 0xFFFFFFFF):
                    return False
                written = ctypes.c_ulong(0)
                ok = ctypes.windll.kernel32.WriteFile(
                    h, payload, len(payload), ctypes.byref(written), None
                )
                ctypes.windll.kernel32.CloseHandle(h)
                return bool(ok)
            except Exception:
                return False
        try:
            import socket

            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.5)
            s.connect(self.ipc)
            s.sendall(payload)
            s.close()
            return True
        except Exception:
            return False

    def toggle_pause(self) -> bool:
        if self._ipc({"command": ["cycle", "pause"]}):
            self.paused = not self.paused
            return True
        return False

    def set_volume(self, vol: int):
        self.volume = max(0, min(100, int(vol)))
        self._ipc({"command": ["set_property", "volume", self.volume]})

    def change_volume(self, delta: int) -> int:
        self.set_volume(self.volume + delta)
        return self.volume


# ---------------------------------------------------------------------------
# 主界面
# ---------------------------------------------------------------------------
class TVPlayerApp:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("TV Player")
        self.root.geometry("1200x700")
        self.root.minsize(900, 520)
        self.root.configure(bg="#000000")

        self.storage = Storage()
        self.channels: list[Channel] = []
        self.filtered: list[Channel] = []
        self.source_urls: list[str] = []
        self.active_source_url = DEFAULT_SOURCE_URL
        self.current_index = 0
        self.current_source_index = 0
        self.panel_visible = False
        self.locked = False
        self.loading = False
        self.waiting_ready = False
        self.auto_switching = False
        self.playback_token = 0
        self.fav_only = False

        self._stall_id = None
        self._osd_id = None
        self._ind_id = None
        self._float_id = None
        self._ready_id = None
        self._watch_id = None

        self.mpv_path = find_mpv()
        self.player = MpvPlayer(self.mpv_path)

        self._restore_sources()
        self._build_ui()
        self._bind_keys()
        self.root.after(80, self._dark_titlebar)
        self.root.after(150, self._startup)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ---- sources ----
    def _restore_sources(self):
        urls = OrderedDict()
        for p in PRESET_SOURCES:
            urls[p["url"]] = True
        for u in self.storage.load_source_urls():
            if u and u.strip():
                urls[u.strip()] = True
        self.source_urls = list(urls.keys())
        selected = (self.storage.load_selected() or "").strip()
        if selected:
            self.active_source_url = selected
            if selected not in self.source_urls:
                self.source_urls.append(selected)
        else:
            self.active_source_url = DEFAULT_SOURCE_URL
        self._persist_sources()

    def _persist_sources(self):
        self.storage.save_source_urls(self.source_urls)
        self.storage.save_selected(self.active_source_url)

    def _candidates(self) -> list[str]:
        urls = [self.active_source_url]
        if self.active_source_url == DEFAULT_SOURCE_URL:
            for m in DEFAULT_MIRRORS:
                if m not in urls:
                    urls.append(m)
        elif "raw.githubusercontent.com" in self.active_source_url:
            for prefix in MIRROR_PREFIXES:
                mirrored = self.active_source_url.replace(
                    "https://raw.githubusercontent.com/", prefix
                )
                if mirrored not in urls:
                    urls.append(mirrored)
        return urls

    def _http_get(self, url: str) -> str | None:
        try:
            r = requests.get(url, headers=HEADERS, timeout=HTTP_TIMEOUT)
            if 200 <= r.status_code < 300 and r.text:
                return r.text
        except Exception:
            return None
        return None

    def _fetch_channels(self) -> list[Channel]:
        for url in self._candidates():
            body = self._http_get(url)
            if not body:
                continue
            parsed = M3UParser.parse(body)
            if parsed:
                return parsed
        return []

    # ---- UI ----
    def _build_ui(self):
        self.area = tk.Frame(self.root, bg="#000000")
        self.area.pack(fill=tk.BOTH, expand=True)

        self.video = tk.Canvas(self.area, bg="#000000", highlightthickness=0)
        self.video.pack(fill=tk.BOTH, expand=True)
        self.video.bind("<Button-1>", lambda e: self._on_tap())

        # 左侧频道面板
        self.panel = tk.Frame(self.area, bg="#1E1E1E", width=300)
        self.panel.pack_propagate(False)

        top = tk.Frame(self.panel, bg="#1E1E1E")
        top.pack(fill=tk.X, padx=8, pady=8)
        self.search_var = tk.StringVar()
        self.search_var.trace_add("write", lambda *_: self._refresh_list())
        tk.Entry(
            top,
            textvariable=self.search_var,
            bg="#2a2a2a",
            fg="#e0e0e0",
            insertbackground="#e0e0e0",
            relief=tk.FLAT,
            font=("", 11),
        ).pack(fill=tk.X, ipady=4)

        btns = tk.Frame(self.panel, bg="#1E1E1E")
        btns.pack(fill=tk.X, padx=8, pady=(0, 6))
        for text, cmd, color in (
            ("刷新", lambda: self.load_channels(True), "#0e639c"),
            ("源管理", self.open_source_dialog, "#0e639c"),
            ("收藏", self._toggle_fav_filter, "#0e639c"),
        ):
            tk.Button(
                btns,
                text=text,
                command=cmd,
                bg=color,
                fg="white",
                relief=tk.FLAT,
                font=("", 10),
            ).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=2)

        list_wrap = tk.Frame(self.panel, bg="#1E1E1E")
        list_wrap.pack(fill=tk.BOTH, expand=True, padx=6)
        self.listbox = tk.Listbox(
            list_wrap,
            bg="#1E1E1E",
            fg="#e0e0e0",
            selectbackground="#094771",
            selectforeground="white",
            font=("", 12),
            relief=tk.FLAT,
            highlightthickness=0,
            activestyle="none",
            exportselection=False,
        )
        sb = tk.Scrollbar(list_wrap, command=self.listbox.yview)
        self.listbox.configure(yscrollcommand=sb.set)
        sb.pack(side=tk.RIGHT, fill=tk.Y)
        self.listbox.pack(fill=tk.BOTH, expand=True)
        self.listbox.bind("<<ListboxSelect>>", self._on_list_select)
        self.listbox.bind("<Button-3>", self._ctx_menu)

        self.status = tk.Label(
            self.panel, text="就绪", bg="#1E1E1E", fg="#888888", font=("", 10), anchor="w"
        )
        self.status.pack(fill=tk.X, padx=10, pady=6)

        # 悬浮层
        self.osd = tk.Label(self.area, text="", bg="#000000", fg="#cccccc", font=("", 13))
        self.indicator = tk.Label(
            self.area, text="", bg="#333333", fg="white", font=("", 16), padx=18, pady=10
        )
        self.btn_panel = tk.Button(
            self.area,
            text="▶",
            bg="#222222",
            fg="#e0e0e0",
            relief=tk.FLAT,
            font=("", 14),
            command=self.toggle_panel,
        )
        self.btn_panel.bind("<Button-3>", lambda e: self.open_source_dialog())
        self.btn_lock = tk.Button(
            self.area,
            text="🔓",
            bg="#222222",
            fg="#e0e0e0",
            relief=tk.FLAT,
            font=("", 14),
            command=self.toggle_lock,
        )
        self.btn_lock.bind("<Button-3>", lambda e: self.confirm_delete_line())

        # 顶部信息条（始终可见一点状态）
        self.info = tk.Label(
            self.area,
            text="",
            bg="#111111",
            fg="#aaaaaa",
            font=("", 10),
            anchor="w",
            padx=8,
        )

        self.root.bind("<Configure>", lambda e: self._layout())
        self._layout()
        self._set_panel(False)
        self._show_floats(True)

    def _layout(self):
        self.root.update_idletasks()
        w = max(self.area.winfo_width(), 1)
        h = max(self.area.winfo_height(), 1)
        self.info.place(x=0, y=0, width=w, height=24)
        self.btn_panel.place(x=8, y=32, width=44, height=44)
        self.btn_lock.place(x=8, y=h - 52, width=44, height=44)
        self.osd.place(relx=0.5, y=56, anchor="n")
        self.indicator.place(relx=0.5, rely=0.5, anchor="center")
        if self.panel_visible and not self.locked:
            self.panel.place(x=0, y=24, width=300, height=h - 24)
            self.panel.lift()
        else:
            self.panel.place_forget()
        self.btn_panel.lift()
        self.btn_lock.lift()
        self.osd.lift()
        self.indicator.lift()
        self.info.lift()

    def _bind_keys(self):
        self.root.bind("<Left>", lambda e: self.switch_line(-1))
        self.root.bind("<Right>", lambda e: self.switch_line(1))
        self.root.bind("<Up>", lambda e: self.prev_channel())
        self.root.bind("<Down>", lambda e: self.next_channel())
        self.root.bind("<space>", lambda e: self._on_tap())
        self.root.bind("<F5>", lambda e: self.load_channels(True))
        self.root.bind("<Escape>", lambda e: self.toggle_panel() if not self.locked else None)
        self.root.bind("s", lambda e: self.open_source_dialog())
        self.root.bind("S", lambda e: self.open_source_dialog())
        self.root.bind("l", lambda e: self.toggle_lock())
        self.root.bind("L", lambda e: self.toggle_lock())
        self.root.bind("<Delete>", lambda e: self.confirm_delete_line())
        self.root.bind("<Control-Left>", lambda e: self._vol(-10))
        self.root.bind("<Control-Right>", lambda e: self._vol(10))

    def _dark_titlebar(self):
        try:
            self.root.update_idletasks()
            hwnd = ctypes.windll.user32.GetParent(self.root.winfo_id())
            val = ctypes.c_int(1)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(hwnd, 20, ctypes.byref(val), 4)
            val2 = ctypes.c_int(2)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(hwnd, 38, ctypes.byref(val2), 4)
        except Exception:
            pass

    # ---- panel / lock / floats ----
    def _set_panel(self, visible: bool):
        self.panel_visible = visible
        self.btn_panel.config(text="◀" if visible else "▶")
        self._layout()

    def toggle_panel(self):
        if self.locked:
            return
        self._set_panel(not self.panel_visible)
        self._flash_floats()

    def toggle_lock(self):
        self.locked = not self.locked
        self.btn_lock.config(text="🔒" if self.locked else "🔓")
        if self.locked:
            self._set_panel(False)
            self._show_floats(True)
            self.btn_panel.place_forget()
            self.show_tip("已锁定")
        else:
            self._flash_floats()
            self.show_tip("已解锁")

    def _show_floats(self, visible: bool):
        h = max(self.area.winfo_height(), 100)
        if visible:
            self.btn_lock.place(x=8, y=h - 52, width=44, height=44)
            if not self.locked:
                self.btn_panel.place(x=8, y=32, width=44, height=44)
            else:
                self.btn_panel.place_forget()
        else:
            self.btn_lock.place_forget()
            self.btn_panel.place_forget()

    def _flash_floats(self):
        if self._float_id:
            self.root.after_cancel(self._float_id)
            self._float_id = None
        self._show_floats(True)
        if self.player.alive() and not self.waiting_ready:
            self._float_id = self.root.after(FLOAT_HIDE_MS, lambda: self._show_floats(False))

    def show_tip(self, text: str):
        self.indicator.config(text=text)
        self.indicator.lift()
        if self._ind_id:
            self.root.after_cancel(self._ind_id)
        self._ind_id = self.root.after(1200, lambda: self.indicator.config(text=""))

    def show_osd(self):
        ch = self._cur()
        if not ch:
            return
        text = f"{self.current_index + 1}/{len(self.channels)} {ch.name}"
        if ch.source_count > 1:
            text += f"  线路 {self.current_source_index + 1}/{ch.source_count}"
        self.osd.config(text=text)
        self.osd.lift()
        if self._osd_id:
            self.root.after_cancel(self._osd_id)
        self._osd_id = self.root.after(CHANNEL_OSD_MS, lambda: self.osd.config(text=""))

    def _set_info(self, text: str):
        self.info.config(text=text)
        self.status.config(text=text)

    # ---- load ----
    def _startup(self):
        if not self.mpv_path:
            messagebox.showwarning(
                "未找到 mpv",
                f"请安装 mpv 到:\n{Path.home() / 'mpv' / 'mpv.exe'}\n或加入 PATH",
            )
        cached = apply_channel_line_rules(self.storage.load_channels(), self.storage)
        if cached:
            self.channels = cached
            self._refresh_list()
            self._set_info(f"缓存 {len(self.channels)} 频道 | 源: {source_display_name(self.active_source_url)}")
            self.current_index = 0
            self.current_source_index = 0
            self.play_current(False, CHANNEL_SWITCH_TIMEOUT_MS)
            self.load_channels(force=True)
        else:
            self.load_channels(force=True)

    def load_channels(self, force=True):
        if self.loading:
            return
        self.loading = True
        self.waiting_ready = False
        self._cancel_stall()
        src_name = source_display_name(self.active_source_url)
        self._set_info(f"正在加载: {src_name} ...")
        self.show_tip("加载频道...")

        def work():
            loaded = self._fetch_channels()
            self.root.after(0, lambda: self._on_loaded(loaded))

        threading.Thread(target=work, daemon=True).start()

    def _on_loaded(self, loaded: list[Channel]):
        self.loading = False
        filtered = apply_channel_line_rules(loaded, self.storage)
        if not filtered:
            if not self.channels:
                self._set_info("加载失败，请打开「源管理」换源或检查网络")
                self.show_tip("加载失败")
            else:
                self._set_info(f"刷新失败，仍使用缓存 {len(self.channels)} 频道")
            return
        self.storage.save_channels(loaded)
        self.channels = filtered
        self._refresh_list()
        self._set_info(
            f"已加载 {len(self.channels)} 频道 | 源: {source_display_name(self.active_source_url)}"
        )
        self.show_tip(f"{len(self.channels)} 个频道")
        self.current_index = min(self.current_index, len(self.channels) - 1)
        self.current_source_index = 0
        self.play_current(False, CHANNEL_SWITCH_TIMEOUT_MS)

    def _refresh_list(self):
        kw = (self.search_var.get() or "").strip().lower()
        result = []
        for ch in self.channels:
            if self.fav_only and not self.storage.is_favorite(ch.key):
                continue
            if kw and kw not in ch.name.lower() and kw not in (ch.group or "").lower():
                continue
            result.append(ch)
        self.filtered = result
        self.listbox.delete(0, tk.END)
        for ch in result:
            star = "★ " if self.storage.is_favorite(ch.key) else ""
            extra = f"  ({ch.source_count})" if ch.source_count > 1 else ""
            self.listbox.insert(tk.END, f"{star}{ch.name}{extra}")
        # 高亮当前
        if 0 <= self.current_index < len(self.channels):
            cur = self.channels[self.current_index]
            for i, ch in enumerate(self.filtered):
                if ch.key == cur.key:
                    self.listbox.selection_clear(0, tk.END)
                    self.listbox.selection_set(i)
                    self.listbox.see(i)
                    break

    def _on_list_select(self, _e=None):
        if self.locked:
            return
        sel = self.listbox.curselection()
        if not sel:
            return
        idx = sel[0]
        if not (0 <= idx < len(self.filtered)):
            return
        ch = self.filtered[idx]
        for i, c in enumerate(self.channels):
            if c.key == ch.key:
                if i == self.current_index and self.player.alive():
                    return
                self.current_index = i
                self.current_source_index = 0
                self.play_current(True)
                break

    # ---- play ----
    def _cur(self) -> Channel | None:
        if not self.channels or not (0 <= self.current_index < len(self.channels)):
            return None
        return self.channels[self.current_index]

    def _cur_url(self) -> str:
        ch = self._cur()
        if not ch or not ch.urls:
            return ""
        if not (0 <= self.current_source_index < ch.source_count):
            self.current_source_index = 0
        return ch.urls[self.current_source_index]

    def play_current(self, show_osd=True, timeout_ms=CHANNEL_SWITCH_TIMEOUT_MS):
        ch = self._cur()
        url = self._cur_url()
        if not ch or not url:
            self.show_tip("当前频道地址无效")
            return
        if not self.mpv_path:
            self.show_tip("未找到 mpv")
            return

        self._refresh_list()
        self.playback_token += 1
        token = self.playback_token
        self.waiting_ready = True
        self.auto_switching = False
        self._cancel_stall()
        self._schedule_stall(timeout_ms, token)

        self.video.update_idletasks()
        wid = self.video.winfo_id()
        if not self.player.play(url, wid):
            self.waiting_ready = False
            self._cancel_stall()
            self.switch_next_line("当前线路播放失败，切换下一线路")
            return

        line = f"{ch.name}"
        if ch.source_count > 1:
            line += f" [{self.current_source_index + 1}/{ch.source_count}]"
        self._set_info(
            f"{self.current_index + 1}/{len(self.channels)} {line} | {source_display_name(self.active_source_url)}"
        )
        if show_osd:
            self.show_osd()
        self._flash_floats()
        self._arm_ready(token)
        self._arm_watch(token)

        if self.panel_visible and not self.locked and show_osd:
            self.root.after(
                400,
                lambda: self._set_panel(False) if self.panel_visible and not self.locked else None,
            )

    def _arm_ready(self, token: int):
        if self._ready_id:
            self.root.after_cancel(self._ready_id)

        def mark():
            if token != self.playback_token:
                return
            if self.player.alive():
                self.waiting_ready = False
                self.auto_switching = False
                self._cancel_stall()
                self._flash_floats()

        self._ready_id = self.root.after(1800, mark)

    def _arm_watch(self, token: int):
        if self._watch_id:
            self.root.after_cancel(self._watch_id)

        def tick():
            if token != self.playback_token:
                return
            if self.player.alive():
                self._watch_id = self.root.after(800, tick)
                return
            self.waiting_ready = False
            self._cancel_stall()
            self.switch_next_line("当前线路播放失败，切换下一线路")

        self._watch_id = self.root.after(800, tick)

    def _schedule_stall(self, timeout_ms: int, token: int):
        self._cancel_stall()

        def on_timeout():
            if token != self.playback_token or not self.waiting_ready:
                return
            self.waiting_ready = False
            self.switch_next_line("当前线路加载超时，切换下一线路")

        self._stall_id = self.root.after(timeout_ms, on_timeout)

    def _cancel_stall(self):
        if self._stall_id:
            self.root.after_cancel(self._stall_id)
            self._stall_id = None

    def switch_line(self, direction: int):
        if self.locked:
            return
        ch = self._cur()
        if not ch:
            return
        if ch.source_count <= 1:
            self.show_tip("当前频道只有一个来源")
            self.show_osd()
            return
        self.current_source_index = (self.current_source_index + direction) % ch.source_count
        self.play_current(True, STALL_TIMEOUT_MS)

    def switch_next_line(self, hint: str):
        ch = self._cur()
        if not ch:
            self.show_tip(hint)
            return
        if ch.source_count <= 1:
            self.auto_switching = False
            self.show_tip(hint)
            return
        if self.auto_switching:
            return
        self.auto_switching = True
        nxt = (self.current_source_index + 1) % ch.source_count
        self.current_source_index = nxt
        self.show_tip(hint)
        self.play_current(True, STALL_TIMEOUT_MS)

    def next_channel(self):
        if self.locked or not self.channels:
            return
        self.current_index = (self.current_index + 1) % len(self.channels)
        self.current_source_index = 0
        self.play_current(True)

    def prev_channel(self):
        if self.locked or not self.channels:
            return
        self.current_index = (self.current_index - 1 + len(self.channels)) % len(self.channels)
        self.current_source_index = 0
        self.play_current(True)

    def _on_tap(self):
        self._flash_floats()
        if self.locked:
            return
        if self.player.alive():
            self.player.toggle_pause()

    def _vol(self, delta: int):
        v = self.player.change_volume(delta)
        self.show_tip(f"音量 {v}%")

    # ---- 删除线路 ----
    def confirm_delete_line(self):
        ch = self._cur()
        url = self._cur_url()
        if not ch or not url:
            return
        label = f"{ch.name} 线路 {self.current_source_index + 1}"
        if not messagebox.askyesno("删除当前线路", f"确认删除 {label} 并跳到下一线路？"):
            return
        self.storage.hide_line(url)
        keep_idx = self.current_source_index
        rebuilt = []
        for c in self.channels:
            nc = Channel(c.name, c.group, c.key)
            for u in c.urls:
                if not self.storage.is_line_hidden(u):
                    nc.add_url(u)
            if nc.source_count:
                rebuilt.append(nc)
        self.channels = rebuilt
        self._refresh_list()
        if not self.channels:
            self.player.stop()
            self.show_tip("线路已删除")
            return
        if self.current_index >= len(self.channels):
            self.current_index = len(self.channels) - 1
        updated = self.channels[self.current_index]
        if updated.source_count <= 0:
            self.next_channel()
            return
        if keep_idx >= updated.source_count:
            self.current_source_index = 0
        else:
            self.current_source_index = keep_idx
        self.show_tip("已删除当前线路")
        self.play_current(True, STALL_TIMEOUT_MS)

    # ---- 源管理（对齐 Android showSourceInputDialog）----
    def open_source_dialog(self):
        if self.locked:
            return
        dlg = tk.Toplevel(self.root)
        dlg.title("选择直播源")
        dlg.configure(bg="#1E1E1E")
        dlg.geometry("640x480")
        dlg.transient(self.root)
        dlg.grab_set()

        tk.Label(
            dlg,
            text="预置源 / 自定义源（单击切换，默认源不可删除）",
            bg="#1E1E1E",
            fg="#aaaaaa",
            font=("", 10),
        ).pack(anchor="w", padx=12, pady=(12, 4))

        entry = tk.Entry(
            dlg, bg="#2a2a2a", fg="#e0e0e0", insertbackground="#e0e0e0", relief=tk.FLAT, font=("", 11)
        )
        entry.pack(fill=tk.X, padx=12, ipady=5)
        entry.insert(0, "")

        row = tk.Frame(dlg, bg="#1E1E1E")
        row.pack(fill=tk.X, padx=12, pady=8)

        listbox = tk.Listbox(
            dlg,
            bg="#1E1E1E",
            fg="#e0e0e0",
            selectbackground="#094771",
            relief=tk.FLAT,
            highlightthickness=0,
            font=("", 11),
            activestyle="none",
        )
        listbox.pack(fill=tk.BOTH, expand=True, padx=12, pady=(0, 8))

        tip = tk.Label(dlg, text="", bg="#1E1E1E", fg="#888888", anchor="w")
        tip.pack(fill=tk.X, padx=12, pady=(0, 8))

        def refresh():
            listbox.delete(0, tk.END)
            for u in self.source_urls:
                mark = "● " if u == self.active_source_url else "○ "
                listbox.insert(tk.END, f"{mark}{source_display_name(u)}")
            try:
                i = self.source_urls.index(self.active_source_url)
                listbox.selection_set(i)
                listbox.see(i)
            except ValueError:
                pass
            tip.config(text=f"当前: {self.active_source_url}")

        def add():
            url = entry.get().strip()
            if not url:
                tip.config(text="源地址不能为空")
                return
            if not url.startswith("http"):
                tip.config(text="请输入 http/https 地址")
                return
            if url not in self.source_urls:
                self.source_urls.append(url)
                self._persist_sources()
            entry.delete(0, tk.END)
            refresh()
            self.select_source(url)
            dlg.destroy()

        def delete():
            sel = listbox.curselection()
            if not sel:
                tip.config(text="请先选择要删除的源")
                return
            target = self.source_urls[sel[0]]
            # 预置 builtin 中的默认源不可删；其它预置可从列表移除自定义副本，但默认源 URL 保留
            if target == DEFAULT_SOURCE_URL:
                tip.config(text="默认源不能删除")
                return
            # 允许删除非默认预置以外的自定义；预置也可从列表隐藏但下次启动会回来
            # 这里：非 DEFAULT 都可删（与 Android 一致：仅 DEFAULT 不可删）
            self.source_urls.pop(sel[0])
            if target == self.active_source_url:
                self.active_source_url = DEFAULT_SOURCE_URL
                self._persist_sources()
                refresh()
                dlg.destroy()
                self.reload_source()
                return
            self._persist_sources()
            refresh()

        def on_pick(_e=None):
            sel = listbox.curselection()
            if not sel:
                return
            self.select_source(self.source_urls[sel[0]])
            dlg.destroy()

        tk.Button(row, text="添加", bg="#0e639c", fg="white", relief=tk.FLAT, command=add).pack(
            side=tk.LEFT, padx=(0, 6)
        )
        tk.Button(row, text="删除", bg="#c0392b", fg="white", relief=tk.FLAT, command=delete).pack(
            side=tk.LEFT, padx=(0, 6)
        )
        tk.Button(
            row,
            text="刷新当前源",
            bg="#27ae60",
            fg="white",
            relief=tk.FLAT,
            command=lambda: (dlg.destroy(), self.load_channels(True)),
        ).pack(side=tk.LEFT, padx=(0, 6))
        tk.Button(row, text="关闭", bg="#555555", fg="white", relief=tk.FLAT, command=dlg.destroy).pack(
            side=tk.RIGHT
        )

        listbox.bind("<Double-Button-1>", on_pick)
        listbox.bind("<Return>", on_pick)
        refresh()
        entry.focus_set()

    def select_source(self, url: str):
        clean = (url or "").strip()
        if not clean:
            self.show_tip("源地址不能为空")
            return
        if clean == self.active_source_url and self.channels:
            self.show_tip("已是当前源")
            return
        self.active_source_url = clean
        if clean not in self.source_urls:
            self.source_urls.append(clean)
        self._persist_sources()
        self.reload_source()

    def reload_source(self):
        self.channels = []
        self.filtered = []
        self.listbox.delete(0, tk.END)
        self.current_index = 0
        self.current_source_index = 0
        self.player.stop()
        self._set_info(f"正在切换源: {source_display_name(self.active_source_url)}")
        self._show_floats(True)
        self.load_channels(True)

    # ---- 右键菜单 ----
    def _ctx_menu(self, event):
        if self.locked:
            return
        idx = self.listbox.nearest(event.y)
        if not (0 <= idx < len(self.filtered)):
            return
        ch = self.filtered[idx]
        menu = tk.Menu(
            self.root,
            tearoff=0,
            bg="#2d2d2d",
            fg="#e0e0e0",
            activebackground="#094771",
            activeforeground="white",
        )
        if self.storage.is_favorite(ch.key):
            menu.add_command(
                label="取消收藏",
                command=lambda: (self.storage.toggle_favorite(ch.key), self._refresh_list()),
            )
        else:
            menu.add_command(
                label="添加收藏",
                command=lambda: (self.storage.toggle_favorite(ch.key), self._refresh_list()),
            )
        menu.add_separator()
        menu.add_command(label="复制当前线路", command=lambda: self._copy(ch))
        menu.add_command(label="删除当前线路", command=self.confirm_delete_line)
        menu.add_command(
            label="隐藏频道",
            command=lambda: (
                self.storage.hide_channel(ch.key),
                self._drop_channel(ch.key),
            ),
        )
        menu.add_separator()
        menu.add_command(label="源管理", command=self.open_source_dialog)
        menu.add_command(label="恢复隐藏频道", command=self._unhide)
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def _copy(self, ch: Channel):
        url = self._cur_url() if self._cur() and self._cur().key == ch.key else (ch.urls[0] if ch.urls else "")
        if url:
            self.root.clipboard_clear()
            self.root.clipboard_append(url)
            self.show_tip("已复制")

    def _drop_channel(self, key: str):
        self.channels = [c for c in self.channels if c.key != key]
        if self.current_index >= len(self.channels):
            self.current_index = max(0, len(self.channels) - 1)
        self._refresh_list()
        if self.channels:
            self.current_source_index = 0
            self.play_current(True)

    def _toggle_fav_filter(self):
        self.fav_only = not self.fav_only
        self._refresh_list()
        self.show_tip("仅看收藏" if self.fav_only else "全部频道")

    def _unhide(self):
        self.storage.unhide_all_channels()
        self.show_tip("已恢复隐藏，正在刷新")
        self.load_channels(True)

    def _on_close(self):
        for attr in ("_stall_id", "_osd_id", "_ind_id", "_float_id", "_ready_id", "_watch_id"):
            aid = getattr(self, attr)
            if aid:
                try:
                    self.root.after_cancel(aid)
                except Exception:
                    pass
        self.player.stop()
        self.root.destroy()

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    TVPlayerApp().run()
