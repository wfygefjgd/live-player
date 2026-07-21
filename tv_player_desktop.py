#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TVPlayer Desktop — 按 android-native 逻辑从零实现
对应:
  Channel.java / M3UParser.java / StorageHelper.java / MainActivity.java
播放器: mpv (对应 Android ExoPlayer)
UI: tkinter (对应 activity_main.xml)
"""

from __future__ import annotations

import ctypes
import json
import os
import re
import socket
import subprocess
import threading
import time
import uuid
from collections import OrderedDict
from pathlib import Path
from typing import Callable, List, Optional

import tkinter as tk
from tkinter import messagebox

try:
    import requests
except ImportError as e:
    raise SystemExit("缺少依赖: pip install requests") from e


# =============================================================================
# 常量 — 与 MainActivity.java 一致
# =============================================================================
DEFAULT_SOURCE_URL = (
    "https://raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8"
)
DEFAULT_MIRRORS = [
    DEFAULT_SOURCE_URL,
    "https://ghfast.top/raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
    "https://raw.gitmirror.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
    "https://raw.kkgithub.com/best-fan/iptv-sources/master/cn_all_status.m3u8",
]
CHANNEL_OSD_MS = 2500
CHANNEL_SWITCH_TIMEOUT_MS = 7000
STALL_TIMEOUT_MS = 7000
NETWORK_WAIT_RETRY_MS = 1000
FLOAT_BUTTONS_TIMEOUT_MS = 2500

HTTP_UA = "Mozilla/5.0 (Linux; Android 10)"
HTTP_CONNECT_TIMEOUT = 8
HTTP_READ_TIMEOUT = 10

# 桌面配置目录（对应 SharedPreferences "tvplayer"）
PREF_DIR = Path.home() / ".tvplayer_android_port"
PREF_DIR.mkdir(parents=True, exist_ok=True)


# =============================================================================
# Channel — 对应 Channel.java
# =============================================================================
class Channel:
    def __init__(
        self,
        name: str,
        group: str = "未分组",
        key: Optional[str] = None,
        urls: Optional[List[str]] = None,
    ):
        self.name = name.strip() if name and name.strip() else "未知"
        self.group = group.strip() if group and group.strip() else "未分组"
        self.key = (
            key.strip()
            if key and key.strip()
            else M3UParser.normalize_name(self.name)
        )
        self._urls: List[str] = []
        if urls:
            for u in urls:
                self.add_url(u)

    def add_url(self, url: Optional[str]) -> None:
        if url is None:
            return
        clean = url.strip()
        if not clean or clean in self._urls:
            return
        self._urls.append(clean)

    def get_urls(self) -> List[str]:
        return list(self._urls)

    def get_primary_url(self) -> str:
        return self._urls[0] if self._urls else ""

    def get_source_count(self) -> int:
        return len(self._urls)

    def get_storage_key(self) -> str:
        return self.key


# =============================================================================
# M3UParser — 对应 M3UParser.java
# =============================================================================
class M3UParser:
    GROUP = re.compile(r'group-title="([^"]*)"')
    NAME = re.compile(r",(.+?)$")
    CCTV = re.compile(r"cctv\s*[-_ ]*0*([1-9]\d*)(k|\+)?", re.I)
    TRAILING_NOISE = re.compile(
        r"(fhd|uhd|hd|sd|4k|8k|1080p|720p|576p|50fps|60fps|h264|h265|hevc|hdr|"
        r"高清|超清|标清|蓝光|流畅|高码|高帧|测试|备用\d*|线路\d+|源\d+|"
        r"直播|在线|综合|频道|央视|卫视|中文|台)$",
        re.I,
    )

    @classmethod
    def parse(cls, text: Optional[str]) -> List[Channel]:
        if not text:
            return []
        channels: "OrderedDict[str, Channel]" = OrderedDict()
        pending_name: Optional[str] = None
        pending_group = "未分组"

        for raw in text.splitlines():
            line = raw.strip()
            if line.startswith("#EXTINF:"):
                gm = cls.GROUP.search(line)
                pending_group = gm.group(1) if gm else "未分组"
                nm = cls.NAME.search(line)
                pending_name = nm.group(1).strip() if nm else "未知"
            elif line and not line.startswith("#") and pending_name is not None:
                display_name = cls.normalize_display_name(pending_name)
                key = cls.normalize_name(display_name)
                channel = channels.get(key)
                if channel is None:
                    channel = Channel(display_name, pending_group, key, None)
                    channels[key] = channel
                channel.add_url(line)
                pending_name = None
                pending_group = "未分组"
        return list(channels.values())

    @classmethod
    def normalize_name(cls, name: Optional[str]) -> str:
        if not name:
            return ""
        working = name.strip().lower()
        cctv = cls.CCTV.search(working)
        if cctv:
            suffix = cctv.group(2).upper() if cctv.group(2) else ""
            return f"cctv{int(cctv.group(1))}{suffix}"
        working = re.sub(r"[\s\-—_·.．,，、/\\|()（）\[\]【】:+]+", "", working)
        working = working.replace("中央", "cctv")
        working = working.replace("央视", "cctv")
        working = working.replace("高清", "")
        working = working.replace("超清", "")
        working = working.replace("蓝光", "")
        working = working.replace("流畅", "")
        working = working.replace("频道", "")
        working = working.replace("直播", "")
        working = working.replace("在线", "")
        working = re.sub(r"(测试|试看|备份|备用|线路|源)+", "", working)
        working = re.sub(r"(?:第)?0*([1-9]\d*)台$", r"\1", working)
        working = cls._strip_trailing_noise(working)
        return working

    @classmethod
    def normalize_display_name(cls, raw_name: Optional[str]) -> str:
        clean = raw_name.strip() if raw_name else "未知"
        cctv = cls.CCTV.search(clean)
        if cctv:
            suffix = cctv.group(2).upper() if cctv.group(2) else ""
            return f"CCTV-{int(cctv.group(1))}{suffix}"
        clean = re.sub(r"\s+", " ", clean)
        clean = re.sub(
            r"(?i)(高清|超清|蓝光|流畅|频道|直播|在线|测试|备用\d*|线路\d+|源\d+)$",
            "",
            clean,
        ).strip()
        return clean if clean else "未知"

    @classmethod
    def _strip_trailing_noise(cls, value: str) -> str:
        working = value
        while True:
            m = cls.TRAILING_NOISE.search(working)
            if not m:
                break
            working = working[: m.start()]
        return working


# =============================================================================
# StorageHelper — 对应 StorageHelper.java
# =============================================================================
class StorageHelper:
    KEY_CACHE = "channels_cache.json"
    KEY_FAV = "favorites.json"
    KEY_HIDDEN = "hidden.json"
    KEY_CUSTOM_SOURCE_URL = "custom_source_url.json"
    KEY_SOURCE_URLS = "source_urls.json"
    KEY_SELECTED_SOURCE_URL = "selected_source_url.json"
    KEY_HIDDEN_LINES = "hidden_lines.json"

    def __init__(self) -> None:
        PREF_DIR.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        return PREF_DIR / key

    def _read_json(self, key: str, default):
        try:
            p = self._path(key)
            if p.exists():
                return json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            pass
        return default

    def _write_json(self, key: str, data) -> None:
        try:
            self._path(key).write_text(
                json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
            )
        except Exception:
            pass

    def save_channels(self, channels: List[Channel]) -> None:
        arr = []
        for c in channels:
            arr.append(
                {
                    "name": c.name,
                    "group": c.group,
                    "key": c.key,
                    "urls": c.get_urls(),
                }
            )
        self._write_json(self.KEY_CACHE, arr)

    def load_channels(self) -> List[Channel]:
        result: List[Channel] = []
        raw = self._read_json(self.KEY_CACHE, None)
        if not raw:
            return result
        try:
            for o in raw:
                urls = list(o.get("urls") or [])
                if not urls and o.get("url"):
                    urls = [o["url"]]
                result.append(
                    Channel(
                        o.get("name", "未知"),
                        o.get("group", "未分组"),
                        o.get("key")
                        or M3UParser.normalize_name(o.get("name", "未知")),
                        urls,
                    )
                )
        except Exception:
            return []
        return result

    def load_favorites(self) -> set:
        return set(self._read_json(self.KEY_FAV, []) or [])

    def save_favorites(self, urls: set) -> None:
        self._write_json(self.KEY_FAV, list(urls))

    def load_hidden(self) -> set:
        return set(self._read_json(self.KEY_HIDDEN, []) or [])

    def save_hidden(self, urls: set) -> None:
        self._write_json(self.KEY_HIDDEN, list(urls))

    def save_custom_source_url(self, url: Optional[str]) -> None:
        self._write_json(self.KEY_CUSTOM_SOURCE_URL, {"url": (url or "").strip()})

    def load_custom_source_url(self) -> str:
        data = self._read_json(self.KEY_CUSTOM_SOURCE_URL, {})
        if isinstance(data, str):
            return data
        return (data or {}).get("url", "") or ""

    def save_source_urls(self, urls: Optional[List[str]]) -> None:
        seen = OrderedDict()
        if urls:
            for url in urls:
                if not url:
                    continue
                clean = url.strip()
                if clean:
                    seen[clean] = True
        self._write_json(self.KEY_SOURCE_URLS, list(seen.keys()))

    def load_source_urls(self) -> List[str]:
        urls: List[str] = []
        raw = self._read_json(self.KEY_SOURCE_URLS, []) or []
        for url in raw:
            u = (url or "").strip()
            if u and u not in urls:
                urls.append(u)
        return urls

    def save_selected_source_url(self, url: Optional[str]) -> None:
        self._write_json(
            self.KEY_SELECTED_SOURCE_URL, {"url": (url or "").strip()}
        )

    def load_selected_source_url(self) -> str:
        data = self._read_json(self.KEY_SELECTED_SOURCE_URL, {})
        if isinstance(data, str) and data.strip():
            return data.strip()
        selected = (data or {}).get("url", "") if isinstance(data, dict) else ""
        if selected and selected.strip():
            return selected.strip()
        return self.load_custom_source_url()

    def load_hidden_lines(self) -> set:
        return set(self._read_json(self.KEY_HIDDEN_LINES, []) or [])

    def save_hidden_lines(self, urls: set) -> None:
        self._write_json(self.KEY_HIDDEN_LINES, list(urls))

    def hide_line(self, url: Optional[str]) -> None:
        if not url or not url.strip():
            return
        hidden = self.load_hidden_lines()
        hidden.add(url.strip())
        self.save_hidden_lines(hidden)

    def is_line_hidden(self, url: Optional[str]) -> bool:
        if not url or not url.strip():
            return False
        return url.strip() in self.load_hidden_lines()


# =============================================================================
# ExoPlayer 替代: mpv 嵌入窗口
# =============================================================================
def find_mpv() -> Optional[str]:
    candidates = [
        Path.home() / "mpv" / "mpv.exe",
        Path(r"C:\Users\96335\mpv\mpv.exe"),
        Path(r"C:\mpv\mpv.exe"),
        Path(r"C:\Program Files\mpv\mpv.exe"),
        "mpv",
    ]
    for c in candidates:
        path = str(c)
        try:
            kw = {"capture_output": True, "timeout": 3}
            if os.name == "nt":
                kw["creationflags"] = subprocess.CREATE_NO_WINDOW
            r = subprocess.run([path, "--version"], **kw)
            if r.returncode == 0:
                return path
        except Exception:
            continue
    return None


class PlayerEngine:
    """对应 ExoPlayer 的最小能力: play / pause / stop / error 检测"""

    def __init__(self, mpv_path: Optional[str]):
        self.mpv_path = mpv_path
        self.proc: Optional[subprocess.Popen] = None
        self.ipc_name = ""
        self.volume = 80
        self.playing = False
        self.on_error: Optional[Callable[[], None]] = None
        self.on_ready: Optional[Callable[[], None]] = None
        self._watch_thread: Optional[threading.Thread] = None
        self._token = 0

    def set_media_and_play(self, url: str, wid: int) -> bool:
        self.stop()
        if not self.mpv_path or not url:
            return False
        pipe = f"tvplayer-{uuid.uuid4().hex}"
        self.ipc_name = rf"\\.\pipe\{pipe}" if os.name == "nt" else str(PREF_DIR / f"{pipe}.sock")
        cmd = [
            self.mpv_path,
            f"--wid={wid}",
            "--no-terminal",
            "--force-window=no",
            "--keep-open=yes",
            "--idle=yes",
            "--cache=yes",
            "--cache-secs=3",
            "--demuxer-max-bytes=50MiB",
            f"--volume={self.volume}",
            f"--input-ipc-server={self.ipc_name}",
            "--input-default-bindings=no",
            "--osc=no",
            "--osd-level=0",
            url,
        ]
        try:
            kw = {
                "stdout": subprocess.DEVNULL,
                "stderr": subprocess.DEVNULL,
                "stdin": subprocess.DEVNULL,
            }
            if os.name == "nt":
                kw["creationflags"] = subprocess.CREATE_NO_WINDOW
            self.proc = subprocess.Popen(cmd, **kw)
            self.playing = True
            self._token += 1
            token = self._token
            self._start_watch(token)
            # 进程存活一段时间视为接近 READY
            threading.Thread(
                target=self._ready_probe, args=(token,), daemon=True
            ).start()
            return True
        except Exception:
            self.proc = None
            self.playing = False
            return False

    def _ready_probe(self, token: int) -> None:
        time.sleep(1.8)
        if token != self._token:
            return
        if self.is_alive() and self.on_ready:
            self.on_ready()

    def _start_watch(self, token: int) -> None:
        def loop():
            while token == self._token:
                time.sleep(0.8)
                if token != self._token:
                    return
                if not self.is_alive():
                    if self.on_error:
                        self.on_error()
                    return

        threading.Thread(target=loop, daemon=True).start()

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def is_playing(self) -> bool:
        return self.is_alive() and self.playing

    def pause(self) -> None:
        if self._cmd(["set_property", "pause", True]):
            self.playing = False

    def play(self) -> None:
        if self._cmd(["set_property", "pause", False]):
            self.playing = True

    def toggle(self) -> None:
        if self.playing:
            self.pause()
        else:
            self.play()

    def stop(self) -> None:
        self._token += 1
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
        self.playing = False

    def clear_media_items(self) -> None:
        self.stop()

    def set_volume(self, vol: int) -> None:
        self.volume = max(0, min(100, int(vol)))
        self._cmd(["set_property", "volume", self.volume])

    def change_volume(self, delta: int) -> int:
        self.set_volume(self.volume + delta)
        return self.volume

    def _cmd(self, command: list) -> bool:
        if not self.ipc_name or not self.is_alive():
            return False
        payload = (json.dumps({"command": command}) + "\n").encode("utf-8")
        if os.name == "nt":
            try:
                GENERIC_WRITE = 0x40000000
                OPEN_EXISTING = 3
                h = ctypes.windll.kernel32.CreateFileW(
                    self.ipc_name, GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None
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
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.4)
            s.connect(self.ipc_name)
            s.sendall(payload)
            s.close()
            return True
        except Exception:
            return False


# =============================================================================
# MainActivity — 对应 MainActivity.java
# =============================================================================
class MainActivity:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title("TVPlayer")
        self.root.geometry("1280x720")
        self.root.minsize(960, 540)
        self.root.configure(bg="#000000")

        # --- 与 MainActivity 字段一致 ---
        self.channels: List[Channel] = []
        # 最近一次成功加载的原始列表（未应用隐藏线路规则），删除线路时用它重建，避免同步联网
        self.raw_channels: List[Channel] = []
        self.source_urls: List[str] = []
        self.storage = StorageHelper()
        self.current_index = 0
        self.current_source_index = 0
        self.panel_visible = False
        self.locked = False
        self.loading = False
        self.waiting_for_ready = False
        self.playback_token = 0
        self.active_source_url = DEFAULT_SOURCE_URL
        self.auto_switching_source = False
        self.current_playback_reached_ready = False
        self.pending_stall_timeout_ms = CHANNEL_SWITCH_TIMEOUT_MS

        self._stall_after = None
        self._hide_indicator_after = None
        self._hide_channel_label_after = None
        self._hide_float_after = None
        # 程序化改 Listbox 选中时忽略 <<ListboxSelect>>，避免与方向键切台重复
        self._ignore_list_select = False

        self.mpv_path = find_mpv()
        self.player = PlayerEngine(self.mpv_path)
        self.player.on_error = lambda: self.root.after(
            0, self._on_player_error
        )
        self.player.on_ready = lambda: self.root.after(
            0, self._on_player_ready
        )

        self.restore_source_state()
        self.bind_views()
        self.setup_list()
        self.setup_buttons()
        self.setup_keys()
        self.root.after(50, self._apply_dark_title)
        self.root.after(100, self.load_channels)
        self.root.protocol("WM_DELETE_WINDOW", self.on_destroy)

    # ----- bindViews -----
    def bind_views(self) -> None:
        self.area = tk.Frame(self.root, bg="#000000")
        self.area.pack(fill=tk.BOTH, expand=True)

        # player_view
        self.player_view = tk.Canvas(
            self.area, bg="#000000", highlightthickness=0, cursor="hand2"
        )
        self.player_view.pack(fill=tk.BOTH, expand=True)
        self.player_view.bind("<Button-1>", lambda e: self.on_single_tap())

        # left_panel
        self.left_panel = tk.Frame(self.area, bg="#1E1E1E", width=280)
        self.left_panel.pack_propagate(False)

        self.channel_list = tk.Listbox(
            self.left_panel,
            bg="#1E1E1E",
            fg="#E0E0E0",
            selectbackground="#094771",
            selectforeground="#FFFFFF",
            font=("", 13),
            relief=tk.FLAT,
            highlightthickness=0,
            activestyle="none",
            exportselection=False,
            borderwidth=0,
        )
        sb = tk.Scrollbar(self.left_panel, command=self.channel_list.yview)
        self.channel_list.configure(yscrollcommand=sb.set)
        sb.pack(side=tk.RIGHT, fill=tk.Y)
        self.channel_list.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

        self.status = tk.Label(
            self.left_panel,
            text="",
            bg="#1E1E1E",
            fg="#888888",
            font=("", 10),
            anchor="w",
        )
        self.status.pack(fill=tk.X, padx=8, pady=4)

        # channel_label (OSD)
        self.channel_label = tk.Label(
            self.area, text="", bg="#000000", fg="#CCCCCC", font=("", 13)
        )
        # indicator
        self.indicator = tk.Label(
            self.area,
            text="",
            bg="#333333",
            fg="#FFFFFF",
            font=("", 16),
            padx=20,
            pady=10,
        )
        # btn_toggle_panel
        self.btn_toggle_panel = tk.Button(
            self.area,
            text="▶",
            bg="#222222",
            fg="#E0E0E0",
            relief=tk.FLAT,
            font=("", 14),
            command=self._on_toggle_click,
        )
        # 长按 → 源管理 (桌面用右键)
        self.btn_toggle_panel.bind(
            "<Button-3>", lambda e: self._on_toggle_long()
        )
        # btn_lock
        self.btn_lock = tk.Button(
            self.area,
            text="🔓",
            bg="#222222",
            fg="#E0E0E0",
            relief=tk.FLAT,
            font=("", 14),
            command=self.toggle_lock,
        )
        self.btn_lock.bind(
            "<Button-3>", lambda e: self._on_lock_long()
        )

        self.root.bind("<Configure>", lambda e: self._layout())
        # 初始: 面板隐藏, 浮钮显示
        self.channel_label.place_forget()
        self.status.config(text="")
        self.set_floating_buttons_visible(True)
        self.left_panel.place_forget()
        self.btn_toggle_panel.config(text="▶")
        self.panel_visible = False
        self._layout()

    def _layout(self) -> None:
        self.root.update_idletasks()
        w = max(self.area.winfo_width(), 1)
        h = max(self.area.winfo_height(), 1)
        self.btn_toggle_panel.place(x=8, y=8, width=44, height=44)
        self.btn_lock.place(x=8, y=h - 52, width=44, height=44)
        if self.panel_visible and not self.locked:
            self.left_panel.place(x=0, y=0, width=280, height=h)
            self.left_panel.lift()
        else:
            self.left_panel.place_forget()
        self.btn_toggle_panel.lift()
        self.btn_lock.lift()
        self.channel_label.lift()
        self.indicator.lift()

    # ----- setupList -----
    def setup_list(self) -> None:
        # 仅鼠标点选切台；方向键交给全局逻辑，并阻断 Listbox 默认移动
        self.channel_list.bind("<<ListboxSelect>>", self._on_channel_click)
        self.channel_list.bind("<ButtonRelease-1>", self._on_channel_click)
        for seq, handler in (
            ("<Up>", lambda e: self._key_channel(-1)),
            ("<Down>", lambda e: self._key_channel(1)),
            ("<Left>", lambda e: self._key_line(-1)),
            ("<Right>", lambda e: self._key_line(1)),
        ):
            self.channel_list.bind(seq, handler)

    def _key_channel(self, direction: int):
        if direction > 0:
            self.play_next_channel(True)
        else:
            self.play_previous_channel(True)
        return "break"

    def _key_line(self, direction: int):
        self.switch_source(direction, True)
        return "break"

    def _on_channel_click(self, _event=None) -> None:
        if self._ignore_list_select or self.locked:
            return
        sel = self.channel_list.curselection()
        if not sel:
            return
        position = sel[0]
        if position < 0 or position >= len(self.channels):
            return
        # 点到当前频道不重复起播
        if position == self.current_index and self.player.is_alive():
            return
        self.current_index = position
        self.current_source_index = 0
        self.play_current(True)

    def adapter_set_data(self, channels: List[Channel]) -> None:
        self._ignore_list_select = True
        try:
            self.channel_list.delete(0, tk.END)
            for ch in channels:
                self.channel_list.insert(tk.END, ch.name)
        finally:
            self.root.after_idle(self._clear_ignore_list_select)

    def adapter_set_selected(self, index: int) -> None:
        self._ignore_list_select = True
        try:
            self.channel_list.selection_clear(0, tk.END)
            if 0 <= index < self.channel_list.size():
                self.channel_list.selection_set(index)
                self.channel_list.activate(index)
                self.channel_list.see(index)
        finally:
            self.root.after_idle(self._clear_ignore_list_select)

    def _clear_ignore_list_select(self) -> None:
        self._ignore_list_select = False

    # ----- setupButtons -----
    def setup_buttons(self) -> None:
        pass  # 已在 bind_views 绑定

    def _on_toggle_click(self) -> None:
        if not self.locked:
            self.toggle_panel()

    def _on_toggle_long(self) -> None:
        if not self.locked:
            self.show_source_input_dialog()

    def _on_lock_long(self) -> None:
        if self.channels:
            self.confirm_delete_current_line()

    # ----- keys (对应 onKeyDown / 手势) -----
    def setup_keys(self) -> None:
        # 用 bind_all，保证焦点在列表/画面时都只走一套逻辑
        self.root.bind_all("<Left>", lambda e: self._global_key_line(-1))
        self.root.bind_all("<Right>", lambda e: self._global_key_line(1))
        self.root.bind_all("<Up>", lambda e: self._global_key_channel(-1))
        self.root.bind_all("<Down>", lambda e: self._global_key_channel(1))
        self.root.bind_all("<space>", lambda e: self._global_space(e))
        self.root.bind_all("<Control-Left>", lambda e: self.adjust_volume(-5))
        self.root.bind_all("<Control-Right>", lambda e: self.adjust_volume(5))
        self.root.bind_all("s", lambda e: self._on_toggle_long())
        self.root.bind_all("S", lambda e: self._on_toggle_long())
        self.root.bind_all("<Delete>", lambda e: self._on_lock_long())
        self.root.bind_all("l", lambda e: self.toggle_lock())
        self.root.bind_all("L", lambda e: self.toggle_lock())
        self.root.bind_all("<F5>", lambda e: self.load_channels())
        self.root.bind_all("<Escape>", lambda e: self._on_toggle_click())

    def _dialog_focused(self) -> bool:
        try:
            w = self.root.focus_get()
            while w is not None:
                if isinstance(w, tk.Toplevel) and w is not self.root:
                    return True
                w = w.master if hasattr(w, "master") else None
        except Exception:
            pass
        return False

    def _global_key_channel(self, direction: int):
        if self._dialog_focused():
            return
        if direction > 0:
            self.play_next_channel(True)
        else:
            self.play_previous_channel(True)
        return "break"

    def _global_key_line(self, direction: int):
        if self._dialog_focused():
            return
        self.switch_source(direction, True)
        return "break"

    def _global_space(self, _event=None):
        if self._dialog_focused():
            return
        self.on_single_tap()
        return "break"

    def on_single_tap(self) -> None:
        if self.locked:
            self.show_floating_buttons_temporarily()
            return
        self.show_floating_buttons_temporarily()
        if self.player.is_alive():
            if self.player.is_playing():
                self.player.pause()
            else:
                self.player.play()

    # ----- player callbacks -----
    def _on_player_ready(self) -> None:
        self.waiting_for_ready = False
        self.auto_switching_source = False
        self.current_playback_reached_ready = True
        self.cancel_stall_check()
        self.schedule_hide_floating_buttons()

    def _on_player_error(self) -> None:
        self.waiting_for_ready = False
        self.cancel_stall_check()
        self.switch_to_next_playable_source("当前线路播放失败，切换下一线路", True)

    # ----- UI helpers -----
    def show_indicator(self, text: str) -> None:
        self.indicator.config(text=text)
        self.indicator.place(relx=0.5, rely=0.5, anchor="center")
        self.indicator.lift()
        if self._hide_indicator_after:
            self.root.after_cancel(self._hide_indicator_after)
        self._hide_indicator_after = self.root.after(
            1200, lambda: self.indicator.place_forget()
        )

    def show_channel_osd(self) -> None:
        if not self.channels or not (
            0 <= self.current_index < len(self.channels)
        ):
            return
        channel = self.channels[self.current_index]
        text = f"{self.current_index + 1}/{len(self.channels)} {channel.name}"
        if channel.get_source_count() > 1:
            text += (
                f" 线路 {self.current_source_index + 1}/"
                f"{channel.get_source_count()}"
            )
        self.channel_label.config(text=text)
        self.channel_label.place(relx=0.5, y=48, anchor="n")
        self.channel_label.lift()
        if self._hide_channel_label_after:
            self.root.after_cancel(self._hide_channel_label_after)
        self._hide_channel_label_after = self.root.after(
            CHANNEL_OSD_MS, lambda: self.channel_label.place_forget()
        )

    def toggle_panel(self) -> None:
        self.panel_visible = not self.panel_visible
        self.btn_toggle_panel.config(text="◀" if self.panel_visible else "▶")
        self._layout()
        self.show_floating_buttons_temporarily()

    def toggle_lock(self) -> None:
        self.locked = not self.locked
        self.btn_lock.config(text="🔒" if self.locked else "🔓")
        if self.locked:
            self.left_panel.place_forget()
            self.set_floating_buttons_visible(True)
            self.btn_toggle_panel.place_forget()
        else:
            self._layout()
            self.show_floating_buttons_temporarily()

    def set_floating_buttons_visible(self, visible: bool) -> None:
        h = max(self.area.winfo_height(), 100)
        if visible:
            self.btn_lock.place(x=8, y=h - 52, width=44, height=44)
            if self.locked:
                self.btn_toggle_panel.place_forget()
            else:
                self.btn_toggle_panel.place(x=8, y=8, width=44, height=44)
        else:
            self.btn_lock.place_forget()
            self.btn_toggle_panel.place_forget()

    def show_floating_buttons_temporarily(self) -> None:
        self.cancel_hide_floating_buttons()
        self.set_floating_buttons_visible(True)
        self.schedule_hide_floating_buttons()

    def schedule_hide_floating_buttons(self) -> None:
        self.cancel_hide_floating_buttons()
        if not self.player.is_alive() or self.waiting_for_ready:
            return
        if not self.current_playback_reached_ready:
            return
        self._hide_float_after = self.root.after(
            FLOAT_BUTTONS_TIMEOUT_MS,
            lambda: self.set_floating_buttons_visible(False),
        )

    def cancel_hide_floating_buttons(self) -> None:
        if self._hide_float_after:
            self.root.after_cancel(self._hide_float_after)
            self._hide_float_after = None

    def adjust_volume(self, direction: int) -> None:
        vol = self.player.change_volume(direction)
        self.show_indicator(f"音量 {vol}%")

    # ----- 删除当前线路 (confirmDeleteCurrentLine) -----
    def confirm_delete_current_line(self) -> None:
        if not self.channels or not (
            0 <= self.current_index < len(self.channels)
        ):
            return
        channel = self.channels[self.current_index]
        if (
            channel.get_source_count() == 0
            or not (0 <= self.current_source_index < channel.get_source_count())
        ):
            return
        line_label = f"{channel.name} 线路 {self.current_source_index + 1}"
        if not messagebox.askyesno(
            "删除当前线路",
            f"确认删除 {line_label} 并自动跳到下一线路吗？",
        ):
            return
        self.delete_current_line_and_jump()

    def delete_current_line_and_jump(self) -> None:
        if not self.channels or not (
            0 <= self.current_index < len(self.channels)
        ):
            return
        channel = self.channels[self.current_index]
        urls = channel.get_urls()
        if (
            not urls
            or not (0 <= self.current_source_index < len(urls))
        ):
            return
        current_url = urls[self.current_source_index]
        target_key = channel.key
        # 删除后：若还有线路，下一条会顶到原 index；若仅 1 条则频道可能消失
        next_index = -1 if len(urls) <= 1 else self.current_source_index
        old_list_index = self.current_index

        self.storage.hide_line(current_url)

        # 用内存中的原始列表重建（不阻塞联网）。raw 为空时退回当前列表。
        source_for_rules = self.raw_channels if self.raw_channels else self.channels
        rebuilt = self.apply_channel_line_rules(source_for_rules)
        self.channels.clear()
        self.channels.extend(rebuilt)
        self.adapter_set_data(self.channels)
        # 同步缓存为过滤后的可见数据，避免下次启动带回已删线路
        try:
            self.storage.save_channels(self.raw_channels if self.raw_channels else self.channels)
        except Exception:
            pass

        if not self.channels:
            self.player.stop()
            self.current_index = 0
            self.current_source_index = 0
            self.show_indicator("线路已删除")
            self.status.config(text="无可用频道")
            return

        # 按频道 key 定位（删线后列表长度可能变）
        found = -1
        for i, c in enumerate(self.channels):
            if c.key == target_key:
                found = i
                break

        if found < 0:
            # 该频道所有线路已删：停在原位置附近的下一频道
            self.current_index = min(old_list_index, len(self.channels) - 1)
            self.current_source_index = 0
            self.show_indicator("已删除当前线路")
            self.play_current(True, STALL_TIMEOUT_MS)
            return

        self.current_index = found
        updated = self.channels[self.current_index]
        if updated.get_source_count() <= 0:
            self.play_next_channel(True)
            return
        if next_index < 0:
            self.current_source_index = 0
        elif next_index >= updated.get_source_count():
            self.current_source_index = 0
        else:
            self.current_source_index = next_index
        self.show_indicator("已删除当前线路")
        self.status.config(text=f"已加载 {len(self.channels)} 个频道")
        self.play_current(True, STALL_TIMEOUT_MS)

    # ----- loadChannels / fetchChannels -----
    def load_channels(self) -> None:
        if self.loading:
            return
        self.loading = True
        self.waiting_for_ready = False
        self.cancel_stall_check()
        self.status.config(text="加载中...")
        self.show_indicator("加载中...")

        def work():
            loaded = self.fetch_channels()
            self.root.after(0, lambda: self._on_channels_loaded(loaded))

        threading.Thread(target=work, daemon=True).start()

    def _on_channels_loaded(self, loaded: List[Channel]) -> None:
        self.loading = False
        if not loaded:
            if not self.channels:
                self.status.config(text="加载失败")
                self.show_indicator("加载失败")
                messagebox.showwarning("提示", "加载失败")
            else:
                self.status.config(text=f"刷新失败，仍使用 {len(self.channels)} 个频道")
                self.show_indicator("刷新失败")
            return
        # 保留原始列表，供删除线路时本地重建
        self.raw_channels = [
            Channel(c.name, c.group, c.key, c.get_urls()) for c in loaded
        ]
        self.channels.clear()
        self.channels.extend(self.apply_channel_line_rules(self.raw_channels))
        self.adapter_set_data(self.channels)
        if not self.channels:
            self.status.config(text="加载失败（过滤后无频道）")
            self.show_indicator("加载失败")
            return
        self.storage.save_channels(self.raw_channels)
        self.status.config(text=f"已加载 {len(self.channels)} 个频道")
        self.current_index = 0
        self.current_source_index = 0
        self.play_current(False, CHANNEL_SWITCH_TIMEOUT_MS)

    def fetch_channels(self) -> List[Channel]:
        for url in self.build_source_candidates():
            try:
                body = self.http_get(url)
                if body:
                    parsed = M3UParser.parse(body)
                    if parsed:
                        return parsed
            except Exception:
                continue
        return []

    def build_source_candidates(self) -> List[str]:
        urls = [self.active_source_url]
        if self.active_source_url == DEFAULT_SOURCE_URL:
            for mirror in DEFAULT_MIRRORS:
                if mirror not in urls:
                    urls.append(mirror)
        return urls

    def http_get(self, url_str: str) -> Optional[str]:
        try:
            r = requests.get(
                url_str,
                headers={"User-Agent": HTTP_UA},
                timeout=(HTTP_CONNECT_TIMEOUT, HTTP_READ_TIMEOUT),
            )
            if 200 <= r.status_code < 300 and r.text:
                return r.text
        except Exception:
            return None
        return None

    # ----- 源管理 showSourceInputDialog -----
    def show_source_input_dialog(self) -> None:
        dlg = tk.Toplevel(self.root)
        dlg.title("选择直播源")
        dlg.configure(bg="#1E1E1E")
        dlg.geometry("560x420")
        dlg.transient(self.root)
        dlg.grab_set()

        root_fr = tk.Frame(dlg, bg="#1E1E1E", padx=16, pady=16)
        root_fr.pack(fill=tk.BOTH, expand=True)

        entry = tk.Entry(
            root_fr,
            bg="#2a2a2a",
            fg="#E0E0E0",
            insertbackground="#E0E0E0",
            relief=tk.FLAT,
            font=("", 11),
        )
        entry.pack(fill=tk.X, ipady=6)
        entry.insert(0, "")
        # hint 用 placeholder 行为
        tip_label = tk.Label(
            root_fr,
            text="输入新的 m3u 或 m3u8 地址",
            bg="#1E1E1E",
            fg="#888888",
            anchor="w",
        )
        tip_label.pack(fill=tk.X, pady=(4, 8))

        actions = tk.Frame(root_fr, bg="#1E1E1E")
        actions.pack(fill=tk.X, pady=(0, 8))

        listbox = tk.Listbox(
            root_fr,
            bg="#1E1E1E",
            fg="#E0E0E0",
            selectbackground="#094771",
            relief=tk.FLAT,
            highlightthickness=0,
            font=("", 11),
            activestyle="none",
            exportselection=False,
        )
        listbox.pack(fill=tk.BOTH, expand=True)

        dialog_sources = list(self.source_urls)

        def refresh_list():
            listbox.delete(0, tk.END)
            for u in dialog_sources:
                mark = "● " if u == self.active_source_url else "○ "
                label = "默认源" if u == DEFAULT_SOURCE_URL else u
                listbox.insert(tk.END, f"{mark}{label}")
            if self.active_source_url in dialog_sources:
                idx = dialog_sources.index(self.active_source_url)
                listbox.selection_set(idx)
                listbox.see(idx)

        def add_source():
            url = entry.get().strip()
            if not url:
                self.show_indicator("源地址不能为空")
                return
            if url not in dialog_sources:
                dialog_sources.append(url)
                self.source_urls = list(dialog_sources)
                self.persist_source_state()
                refresh_list()
            if url in dialog_sources:
                listbox.selection_clear(0, tk.END)
                listbox.selection_set(dialog_sources.index(url))
            entry.delete(0, tk.END)
            self.select_source(url)
            dlg.destroy()

        def delete_source():
            sel = listbox.curselection()
            if not sel:
                self.show_indicator("请先选择要删除的源")
                return
            idx = sel[0]
            if idx < 0 or idx >= len(dialog_sources):
                return
            target = dialog_sources[idx]
            if target == DEFAULT_SOURCE_URL:
                self.show_indicator("默认源不能删除")
                return
            dialog_sources.pop(idx)
            self.source_urls = [DEFAULT_SOURCE_URL] + [
                u for u in dialog_sources if u != DEFAULT_SOURCE_URL
            ]
            # 保持 dialog 列表与 source_urls 同步
            # Android: sourceUrls.clear(); add DEFAULT; addAll dialogSources
            self.source_urls = [DEFAULT_SOURCE_URL]
            for u in dialog_sources:
                if u not in self.source_urls:
                    self.source_urls.append(u)
            if target == self.active_source_url:
                self.active_source_url = DEFAULT_SOURCE_URL
                self.persist_source_state()
                refresh_list()
                dlg.destroy()
                self.reload_active_source()
                return
            self.persist_source_state()
            refresh_list()

        def on_item_click(_e=None):
            sel = listbox.curselection()
            if not sel:
                return
            selected_url = dialog_sources[sel[0]]
            self.select_source(selected_url)
            dlg.destroy()

        tk.Button(
            actions, text="添加", bg="#0e639c", fg="white", relief=tk.FLAT, command=add_source
        ).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))
        tk.Button(
            actions, text="删除", bg="#c0392b", fg="white", relief=tk.FLAT, command=delete_source
        ).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 0))

        listbox.bind("<Double-Button-1>", on_item_click)
        listbox.bind("<Return>", on_item_click)
        tk.Button(
            root_fr,
            text="关闭",
            bg="#555555",
            fg="white",
            relief=tk.FLAT,
            command=dlg.destroy,
        ).pack(fill=tk.X, pady=(8, 0))

        refresh_list()
        entry.focus_set()

    def select_source(self, url: Optional[str]) -> None:
        clean = (url or "").strip()
        if not clean:
            self.show_indicator("源地址不能为空")
            return
        if clean == self.active_source_url:
            return
        self.active_source_url = clean
        self.persist_source_state()
        self.reload_active_source()

    def reload_active_source(self) -> None:
        self.channels.clear()
        self.raw_channels = []
        self.adapter_set_data(self.channels)
        self.current_index = 0
        self.current_source_index = 0
        self.player.stop()
        self.player.clear_media_items()
        self.status.config(text="正在切换源...")
        self.set_floating_buttons_visible(True)
        self.load_channels()

    def restore_source_state(self) -> None:
        urls = OrderedDict()
        urls[DEFAULT_SOURCE_URL] = True
        for u in self.storage.load_source_urls():
            if u and u.strip():
                urls[u.strip()] = True
        legacy = self.storage.load_custom_source_url()
        if legacy and legacy.strip():
            urls[legacy.strip()] = True
        self.source_urls = list(urls.keys())
        selected = self.storage.load_selected_source_url()
        if selected and selected.strip():
            self.active_source_url = selected.strip()
            if self.active_source_url not in self.source_urls:
                self.source_urls.append(self.active_source_url)
        else:
            self.active_source_url = DEFAULT_SOURCE_URL
        self.persist_source_state()

    def persist_source_state(self) -> None:
        self.storage.save_source_urls(self.source_urls)
        self.storage.save_selected_source_url(self.active_source_url)
        self.storage.save_custom_source_url(self.active_source_url)

    # ----- stall / play -----
    def schedule_stall_check(self, timeout_ms: int) -> None:
        if not self.waiting_for_ready or not self.channels:
            return
        self.cancel_stall_check()
        token = self.playback_token

        def on_timeout():
            if token == self.playback_token and self.waiting_for_ready:
                self.waiting_for_ready = False
                self.switch_to_next_playable_source(
                    "当前线路加载超时，切换下一线路", True
                )

        self._stall_after = self.root.after(timeout_ms, on_timeout)

    def cancel_stall_check(self) -> None:
        if self._stall_after:
            self.root.after_cancel(self._stall_after)
            self._stall_after = None

    def play_current(
        self, show_osd: bool, timeout_ms: int = CHANNEL_SWITCH_TIMEOUT_MS
    ) -> None:
        if not self.channels or not (
            0 <= self.current_index < len(self.channels)
        ):
            return
        channel = self.channels[self.current_index]
        if not (
            0 <= self.current_source_index < channel.get_source_count()
        ):
            self.current_source_index = 0
        urls = channel.get_urls()
        url = urls[self.current_source_index] if urls else ""
        if not url:
            self.waiting_for_ready = False
            self.show_indicator("当前频道地址无效")
            return

        if not self.mpv_path:
            self.show_indicator("未找到 mpv 播放器")
            self.status.config(
                text=f"请安装 mpv 到 {Path.home() / 'mpv' / 'mpv.exe'}"
            )
            return

        self.adapter_set_selected(self.current_index)
        self.playback_token += 1
        self.waiting_for_ready = True
        self.auto_switching_source = False
        self.current_playback_reached_ready = False
        self.pending_stall_timeout_ms = timeout_ms
        self.schedule_stall_check(timeout_ms)

        try:
            self.player_view.update_idletasks()
            wid = self.player_view.winfo_id()
            ok = self.player.set_media_and_play(url, wid)
            if not ok:
                raise RuntimeError("mpv start failed")
            if show_osd:
                self.show_channel_osd()
            if self.panel_visible and not self.locked and show_osd:
                self.root.after(300, self._auto_hide_panel_if_needed)
        except Exception:
            self.waiting_for_ready = False
            self.cancel_stall_check()
            self.switch_to_next_playable_source(
                "当前线路播放失败，切换下一线路", True
            )

    def _auto_hide_panel_if_needed(self) -> None:
        if self.panel_visible and not self.locked:
            self.toggle_panel()

    def play_next_channel(self, show_osd: bool) -> None:
        if not self.channels:
            return
        if self.locked:
            return
        self.current_index = (self.current_index + 1) % len(self.channels)
        self.current_source_index = 0
        self.play_current(show_osd, CHANNEL_SWITCH_TIMEOUT_MS)

    def play_previous_channel(self, show_osd: bool) -> None:
        if not self.channels:
            return
        if self.locked:
            return
        self.current_index = (
            self.current_index - 1 + len(self.channels)
        ) % len(self.channels)
        self.current_source_index = 0
        self.play_current(show_osd, CHANNEL_SWITCH_TIMEOUT_MS)

    def switch_source(self, direction: int, show_osd: bool) -> None:
        if self.locked:
            return
        if not self.channels or not (
            0 <= self.current_index < len(self.channels)
        ):
            return
        channel = self.channels[self.current_index]
        if channel.get_source_count() <= 1:
            self.show_indicator("当前频道只有一个来源")
            if show_osd:
                self.show_channel_osd()
            return
        count = channel.get_source_count()
        self.current_source_index = (
            self.current_source_index + direction + count
        ) % count
        self.play_current(show_osd, STALL_TIMEOUT_MS)

    def switch_to_next_playable_source(
        self, hint: str, show_osd: bool
    ) -> None:
        if not self.channels or not (
            0 <= self.current_index < len(self.channels)
        ):
            self.show_indicator(hint)
            return
        channel = self.channels[self.current_index]
        count = channel.get_source_count()
        if count <= 1:
            self.auto_switching_source = False
            self.show_indicator(hint)
            return
        if self.auto_switching_source:
            return
        self.auto_switching_source = True
        original = self.current_source_index
        nxt = (self.current_source_index + 1) % count
        if nxt == original:
            self.auto_switching_source = False
            self.show_indicator(hint)
            return
        self.current_source_index = nxt
        self.show_indicator(hint)
        self.play_current(show_osd, STALL_TIMEOUT_MS)

    # ----- applyChannelLineRules / shouldSkipChannelLine -----
    def apply_channel_line_rules(
        self, input_list: List[Channel]
    ) -> List[Channel]:
        output: List[Channel] = []
        for source in input_list:
            if source is None:
                continue
            filtered = Channel(source.name, source.group, source.key, None)
            urls = source.get_urls()
            for i, url in enumerate(urls):
                if self.storage.is_line_hidden(url):
                    continue
                if self.should_skip_channel_line(source.key, i, url):
                    continue
                filtered.add_url(url)
            if filtered.get_source_count() > 0:
                output.append(filtered)
        return output

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

    # ----- lifecycle -----
    def _apply_dark_title(self) -> None:
        try:
            self.root.update_idletasks()
            hwnd = ctypes.windll.user32.GetParent(self.root.winfo_id())
            val = ctypes.c_int(1)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, 20, ctypes.byref(val), 4
            )
        except Exception:
            pass

    def on_destroy(self) -> None:
        self.cancel_stall_check()
        self.cancel_hide_floating_buttons()
        for attr in (
            "_hide_indicator_after",
            "_hide_channel_label_after",
        ):
            aid = getattr(self, attr)
            if aid:
                try:
                    self.root.after_cancel(aid)
                except Exception:
                    pass
        self.player.stop()
        self.root.destroy()

    def run(self) -> None:
        if not self.mpv_path:
            messagebox.showwarning(
                "未找到 mpv",
                "请安装 mpv 播放器:\n"
                f"{Path.home() / 'mpv' / 'mpv.exe'}\n"
                "或将 mpv 加入 PATH",
            )
        self.root.mainloop()


# =============================================================================
# entry
# =============================================================================
if __name__ == "__main__":
    MainActivity().run()
