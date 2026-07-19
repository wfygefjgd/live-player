#!/usr/bin/env python3
import sys, re, os, json, threading, time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import ctypes

from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QListWidget,
    QHBoxLayout, QVBoxLayout, QLabel, QLineEdit, QComboBox, QPushButton,
    QProgressBar, QMenu, QCheckBox, QMessageBox, QListWidgetItem,
    QDialog, QScrollArea)
from PySide6.QtCore import Qt, QTimer, Signal, QObject
from PySide6.QtGui import QFont

import vlc, requests

CONFIG_DIR = Path.home() / ".tv_player"
FAVORITES_FILE = CONFIG_DIR / "favorites.json"
HIDDEN_FILE = CONFIG_DIR / "hidden.json"

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

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
}
TIMEOUT = 8

# ============================================================
# Channel
# ============================================================

class Channel:
    def __init__(self, name, url, group="", logo=""):
        self.name = name
        self.url = url
        self.group = group
        self.logo = logo

    def to_dict(self):
        return {"name": self.name, "url": self.url, "group": self.group, "logo": self.logo}

# ============================================================
# M3U Parser
# ============================================================

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
                logo_match = re.search(r'tvg-logo="([^"]*)"', line)
                logo = logo_match.group(1) if logo_match else ""
                name_match = re.search(r",(.+?)$", line)
                name = name_match.group(1).strip() if name_match else "未知"
                j = i + 1
                while j < len(lines):
                    nxt = lines[j].strip()
                    if nxt and not nxt.startswith("#"):
                        channels.append(Channel(name, nxt, group, logo))
                        break
                    j += 1
                i = j + 1
            else:
                i += 1
        return channels

# ============================================================
# Speed Monitor
# ============================================================

class SpeedMonitor:
    def __init__(self):
        self._last_bytes = 0
        self._last_time = 0
        self.speed = 0

    def update(self, bytes_downloaded):
        now = time.time()
        dt = now - self._last_time
        if dt > 0.1:
            self.speed = (bytes_downloaded - self._last_bytes) / dt
            self._last_bytes = bytes_downloaded
            self._last_time = now

    def reset(self):
        self._last_bytes = 0
        self._last_time = 0
        self.speed = 0

    def format_speed(self):
        if self.speed > 1024 * 1024:
            return f"{self.speed / 1024 / 1024:.1f} MB/s"
        elif self.speed > 1024:
            return f"{self.speed / 1024:.0f} KB/s"
        else:
            return f"{self.speed:.0f} B/s"

# ============================================================
# Source Loader
# ============================================================

class LoaderSignals(QObject):
    done = Signal(list)
    err = Signal(str)
    speed_update = Signal(str)

class SpeedTester(threading.Thread):
    def __init__(self, channels):
        super().__init__()
        self.channels = channels
        self._running = True
        self.slow_urls = []

    def run(self):
        def test_one(ch):
            if not self._running:
                return None
            try:
                start = time.time()
                resp = requests.get(ch.url, headers=HEADERS, timeout=6, stream=True)
                chunks = []
                for chunk in resp.iter_content(65536):
                    if not self._running:
                        return None
                    chunks.append(chunk)
                    if len(chunks) >= 3:
                        break
                elapsed = time.time() - start
                downloaded = sum(len(c) for c in chunks)
                speed = downloaded / elapsed if elapsed > 0 else 0
                return (ch, speed, "ok")
            except:
                return (ch, 0, "fail")

        batch_size = 3
        for i in range(0, len(self.channels), batch_size):
            if not self._running:
                break
            batch = self.channels[i:i+batch_size]
            with ThreadPoolExecutor(max_workers=3) as pool:
                futures = {pool.submit(test_one, ch): ch for ch in batch}
                for fut in as_completed(futures):
                    if not self._running:
                        break
                    try:
                        result = fut.result(timeout=10)
                        if result:
                            ch, speed, status = result
                            if speed < 1 * 1024 * 1024 or status == "fail":
                                self.slow_urls.append(ch.url)
                    except:
                        pass

    def stop(self):
        self._running = False

class SourceLoader(threading.Thread):
    def __init__(self, sources):
        super().__init__()
        self.sources = sources
        self.sig = LoaderSignals()
        self._speed_monitor = SpeedMonitor()
        self._running = True

    def run(self):
        all_channels = []
        total_bytes = 0

        def fetch_one(src):
            nonlocal total_bytes
            for url in self._with_mirrors(src["url"]):
                try:
                    resp = requests.get(url, headers=HEADERS, timeout=TIMEOUT, stream=True)
                    resp.raise_for_status()
                    chunks = []
                    for chunk in resp.iter_content(8192):
                        if not self._running:
                            return []
                        if chunk:
                            chunks.append(chunk)
                            total_bytes += len(chunk)
                            self._speed_monitor.update(total_bytes)
                    content = b"".join(chunks).decode("utf-8", errors="replace")
                    return M3UParser.parse(content)
                except:
                    continue
            return []

        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = {}
            for src in self.sources:
                futures[pool.submit(fetch_one, src)] = src

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
            self.sig.done.emit(uniq)
        else:
            self.sig.err.emit("加载失败")

    def stop(self):
        self._running = False

    def _with_mirrors(self, url):
        urls = [url]
        for prefix in MIRROR_PREFIXES:
            if "raw.githubusercontent.com" in url:
                urls.append(url.replace("https://raw.githubusercontent.com/", prefix))
        return urls

    @property
    def speed_text(self):
        return self._speed_monitor.format_speed()

# ============================================================
# VLC Widget
# ============================================================

class VideoWidget(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setStyleSheet("background:#000;")
        self.setAttribute(Qt.WA_OpaquePaintEvent)

        self.overlay = QLabel(self)
        self.overlay.setAlignment(Qt.AlignCenter)
        self.overlay.setStyleSheet(
            "color:#ccc;font-size:20px;background:rgba(0,0,0,180);"
            "border-radius:10px;padding:20px 40px;"
        )
        self.overlay.hide()

        self.vol_label = QLabel("", self)
        self.vol_label.setAlignment(Qt.AlignCenter)
        self.vol_label.setStyleSheet(
            "color:#fff;font-size:24px;font-weight:bold;background:rgba(0,0,0,180);"
            "border-radius:8px;padding:10px 20px;"
        )
        self.vol_label.hide()

        self._inst = vlc.Instance([
            "--network-caching=80", "--live-caching=30",
            "--no-xlib", "--no-video-title-show", "--verbose=-1",
        ])
        self._player = self._inst.media_player_new()
        self._is_playing = False
        self._current_volume = 100
        self._current_url = None

        self._vol_timer = QTimer(self)
        self._vol_timer.setSingleShot(True)
        self._vol_timer.timeout.connect(self.vol_label.hide)

        self._buf_timer = QTimer(self)
        self._buf_timer.setInterval(100)
        self._buf_timer.timeout.connect(self._check_buf)

    def resizeEvent(self, e):
        super().resizeEvent(e)
        w, h = self.width(), self.height()
        self.overlay.setGeometry(w // 4, h // 3, w // 2, 60)
        self.vol_label.adjustSize()
        vw = self.vol_label.width()
        vh = self.vol_label.height()
        self.vol_label.setGeometry((w - vw) // 2, 20, vw, vh)

    def show_msg(self, text):
        self.overlay.setText(text)
        self.overlay.show()
        self.overlay.raise_()

    def hide_msg(self):
        self.overlay.hide()

    def set_volume(self, vol):
        v = max(0, min(100, vol))
        self._current_volume = v
        self._player.audio_set_volume(v)
        self.vol_label.setText(f"音量 {v}")
        self.vol_label.adjustSize()
        w = self.width()
        vw = self.vol_label.width()
        self.vol_label.setGeometry((w - vw) // 2, 20, vw, self.vol_label.height())
        self.vol_label.show()
        self._vol_timer.start(1200)

    def play_url(self, url):
        if url == self._current_url:
            return
        self._current_url = url
        self._is_playing = False

        self._player.stop()

        media = self._inst.media_new(url)
        media.add_option("http-user-agent=" + HEADERS["User-Agent"])
        self._player.set_media(media)

        if sys.platform.startswith("win"):
            self._player.set_hwnd(int(self.winId()))

        self._player.audio_set_volume(self._current_volume)
        self._player.play()
        self._buf_timer.start()
        self.show_msg("缓冲中...")

    def stop_play(self):
        self._player.stop()
        self._is_playing = False
        self._current_url = None
        self._buf_timer.stop()

    def _check_buf(self):
        if self._player.is_playing():
            self._is_playing = True
            self.hide_msg()
            self._buf_timer.stop()

    def toggle_pause(self):
        if self._is_playing:
            self._player.pause()
            self._is_playing = False
            self.show_msg("已暂停")
        else:
            self._player.play()
            self._is_playing = True
            self.hide_msg()

    def closeEvent(self, e):
        self._buf_timer.stop()
        try: self._player.stop()
        except: pass
        try: self._player.release()
        except: pass
        try: self._inst.release()
        except: pass
        super().closeEvent(e)

# ============================================================
# Favorites
# ============================================================

class FavoritesManager:
    def __init__(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        self.favorites = self._load()

    def _load(self):
        try:
            if FAVORITES_FILE.exists():
                return json.loads(FAVORITES_FILE.read_text(encoding="utf-8"))
        except: pass
        return []

    def _save(self):
        FAVORITES_FILE.write_text(json.dumps(self.favorites, ensure_ascii=False), encoding="utf-8")

    def add(self, ch):
        if ch.url not in [f["url"] for f in self.favorites]:
            self.favorites.append(ch.to_dict())
            self._save()
            return True
        return False

    def remove(self, url):
        self.favorites = [f for f in self.favorites if f["url"] != url]
        self._save()

    def is_favorite(self, url):
        return url in [f["url"] for f in self.favorites]

    def get_all(self):
        return [Channel(f["name"], f["url"], f.get("group", "")) for f in self.favorites]

class HiddenManager:
    def __init__(self):
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        self.hidden = set(self._load())

    def _load(self):
        try:
            if HIDDEN_FILE.exists():
                return json.loads(HIDDEN_FILE.read_text(encoding="utf-8"))
        except: pass
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

    def show_all(self):
        self.hidden.clear()
        self._save()

    def is_hidden(self, url):
        return url in self.hidden

# ============================================================
# QSS
# ============================================================

DARK_QSS = """
QMainWindow, QWidget { background:#1E1E1E; color:#e0e0e0; font-family:"Microsoft YaHei UI",sans-serif; }
QListWidget { background:#1E1E1E; border:1px solid #3c3c3c; border-radius:6px; padding:2px; outline:none; font-size:13px; }
QListWidget::item { padding:6px 10px; border-radius:3px; margin:1px 2px; }
QListWidget::item:selected { background:#094771; color:#fff; }
QListWidget::item:hover:!selected { background:#2a2d2e; }
QLineEdit { background:#1E1E1E; border:1px solid #555; border-radius:4px; padding:5px 8px; color:#e0e0e0; font-size:12px; }
QLineEdit:focus { border-color:#0078d4; }
QComboBox { background:#1E1E1E; border:1px solid #555; border-radius:4px; padding:5px 8px; color:#e0e0e0; font-size:12px; }
QComboBox::drop-down { border:none; width:20px; }
QComboBox QAbstractItemView { background:#1E1E1E; color:#e0e0e0; selection-background-color:#094771; }
QPushButton { background:#0e639c; color:#fff; border:none; border-radius:4px; padding:6px 12px; font-size:12px; }
QPushButton:hover { background:#1177bb; }
QPushButton:pressed { background:#094771; }
QPushButton:disabled { background:#555; color:#888; }
QProgressBar { background:#1E1E1E; border:none; border-radius:3px; height:3px; color:transparent; }
QProgressBar::chunk { background:#0078d4; border-radius:3px; }
QScrollBar:vertical { background:#1E1E1E; width:6px; border-radius:3px; }
QScrollBar::handle:vertical { background:#555; min-height:20px; border-radius:3px; }
QScrollBar::handle:vertical:hover { background:#777; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height:0; }
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background:none; }
"""

# ============================================================
# Main Window
# ============================================================

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("TV Player Pro")
        self.resize(1000, 620)
        self._set_dark_title_bar()
        self.channels = []
        self.filtered_channels = []
        self._volume = 100
        self._loading = False
        self._current_group = "全部"
        self._show_fav_only = False
        self._select_mode = False
        self.fav_mgr = FavoritesManager()
        self.hidden_mgr = HiddenManager()
        self._source_idx = 0
        self._loader = None
        self._tester = None
        self._switch_timer = QTimer(self)
        self._switch_timer.setSingleShot(True)
        self._switch_timer.setInterval(50)
        self._switch_timer.timeout.connect(self._do_play)
        self._pending_url = None
        self._speed_timer = QTimer(self)
        self._speed_timer.setInterval(500)
        self._speed_timer.timeout.connect(self._update_speed)

        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QHBoxLayout(central)
        main_layout.setContentsMargins(8, 8, 8, 8)
        main_layout.setSpacing(8)

        left = QWidget()
        left.setFixedWidth(260)
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(0, 0, 0, 0)
        left_layout.setSpacing(4)

        self.search = QLineEdit()
        self.search.setPlaceholderText("搜索...")
        self.search.textChanged.connect(self._filter)
        left_layout.addWidget(self.search)

        ctrl = QHBoxLayout()
        self.group_combo = QComboBox()
        self.group_combo.addItem("全部")
        self.group_combo.currentTextChanged.connect(self._on_group)
        ctrl.addWidget(self.group_combo, 1)
        self.fav_btn = QPushButton("收藏")
        self.fav_btn.setCheckable(True)
        self.fav_btn.clicked.connect(self._toggle_fav)
        ctrl.addWidget(self.fav_btn)
        left_layout.addLayout(ctrl)

        self.ch_list = QListWidget()
        self.ch_list.setFocusPolicy(Qt.NoFocus)
        self.ch_list.currentRowChanged.connect(self._on_select)
        self.ch_list.setContextMenuPolicy(Qt.CustomContextMenu)
        self.ch_list.customContextMenuRequested.connect(self._ctx_menu)
        left_layout.addWidget(self.ch_list, 1)

        btns = QHBoxLayout()
        self.refresh_btn = QPushButton("刷新")
        self.refresh_btn.clicked.connect(self._refresh)
        btns.addWidget(self.refresh_btn)
        self.switch_btn = QPushButton("换源")
        self.switch_btn.clicked.connect(self._switch)
        btns.addWidget(self.switch_btn)
        left_layout.addLayout(btns)

        batch_row = QHBoxLayout()
        self.select_btn = QPushButton("批量选择")
        self.select_btn.setCheckable(True)
        self.select_btn.clicked.connect(self._toggle_select_mode)
        batch_row.addWidget(self.select_btn)
        self.batch_hide_btn = QPushButton("隐藏选中")
        self.batch_hide_btn.clicked.connect(self._batch_hide)
        self.batch_hide_btn.hide()
        batch_row.addWidget(self.batch_hide_btn)
        self.select_all_btn = QPushButton("全选")
        self.select_all_btn.clicked.connect(self._select_all)
        self.select_all_btn.hide()
        batch_row.addWidget(self.select_all_btn)
        left_layout.addLayout(batch_row)

        self.unhide_btn = QPushButton("恢复隐藏频道")
        self.unhide_btn.clicked.connect(self._unhide_all)
        self.unhide_btn.hide()
        left_layout.addWidget(self.unhide_btn)

        self.speed_test_btn = QPushButton("测速隐藏 (<1MB/s)")
        self.speed_test_btn.clicked.connect(self._start_speed_test)
        self.speed_test_btn.hide()
        left_layout.addWidget(self.speed_test_btn)

        self.status_label = QLabel("")
        self.status_label.setStyleSheet("color:#888;font-size:11px;")
        left_layout.addWidget(self.status_label)

        self.progress = QProgressBar()
        self.progress.setMaximum(0)
        self.progress.hide()
        left_layout.addWidget(self.progress)

        main_layout.addWidget(left)

        self.video = VideoWidget()
        main_layout.addWidget(self.video, 1)
        self.video.set_volume(self._volume)
        self._volume = 100

        self.setStyleSheet(DARK_QSS)
        QTimer.singleShot(100, self._refresh)

    def _set_dark_title_bar(self):
        try:
            hwnd = int(self.winId())
            DWMWA_USE_IMMERSIVE_DARK_MODE = 20
            DWMWA_CAPTION_COLOR = 35
            color = 0x1E1E1E
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
                ctypes.byref(ctypes.c_int(1)), ctypes.sizeof(ctypes.c_int)
            )
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, DWMWA_CAPTION_COLOR,
                ctypes.byref(ctypes.c_int(color)), ctypes.sizeof(ctypes.c_int)
            )
        except:
            pass

    def _refresh(self):
        if self._loading:
            return
        self._loading = True
        self.progress.setMaximum(0)
        self.progress.show()
        self.refresh_btn.setEnabled(False)
        self.switch_btn.setEnabled(False)
        self.speed_test_btn.hide()
        self.video.show_msg("加载中...")
        self._load_sources(DEFAULT_SOURCES)

    def _switch(self):
        if self._loading:
            return
        self._source_idx = (self._source_idx + 1) % len(DEFAULT_SOURCES)
        src = DEFAULT_SOURCES[self._source_idx]
        self._loading = True
        self.progress.setMaximum(0)
        self.progress.show()
        self.refresh_btn.setEnabled(False)
        self.switch_btn.setEnabled(False)
        self.speed_test_btn.hide()
        self.video.show_msg(f"切换 {src['name']}...")
        self._load_sources([src])

    def _load_sources(self, sources):
        if self._loader:
            self._loader.stop()
        self._loader = SourceLoader(sources)
        self._loader.sig.done.connect(self._on_done)
        self._loader.sig.err.connect(self._on_err)
        self._loader._speed_monitor.reset()
        self._speed_timer.start()
        self._loader.start()

    def _on_done(self, channels):
        self._loading = False
        self.progress.hide()
        self.refresh_btn.setEnabled(True)
        self.switch_btn.setEnabled(True)
        self._speed_timer.stop()
        self.status_label.setText("")
        self.channels = channels
        self._update_groups()
        self._filter()
        if channels:
            QTimer.singleShot(100, lambda: self.ch_list.setCurrentRow(0))
        self.video.hide_msg()
        self.speed_test_btn.setVisible(len(channels) > 0)

    def _on_err(self, msg):
        self._loading = False
        self.progress.hide()
        self.refresh_btn.setEnabled(True)
        self.switch_btn.setEnabled(True)
        self._speed_timer.stop()
        self.status_label.setText("")
        self.video.show_msg(msg)

    def _update_speed(self):
        if self._loader:
            spd = self._loader.speed_text
            self.status_label.setText(f"加载中... {spd}")

    def _update_groups(self):
        groups = set(ch.group for ch in self.channels)
        self.group_combo.clear()
        self.group_combo.addItem("全部")
        for g in sorted(groups):
            self.group_combo.addItem(g)

    def _on_group(self, group):
        self._current_group = group
        self._filter()

    def _filter(self):
        kw = self.search.text().lower()
        src = self.fav_mgr.get_all() if self._show_fav_only else self.channels
        result = []
        for ch in src:
            if self.hidden_mgr.is_hidden(ch.url):
                continue
            if self._current_group != "全部" and ch.group != self._current_group:
                continue
            if kw and kw not in ch.name.lower():
                continue
            result.append(ch)
        self.filtered_channels = result
        self.ch_list.clear()
        for ch in result:
            p = "★ " if self.fav_mgr.is_favorite(ch.url) else "▸ "
            self.ch_list.addItem(f"{p}{ch.name}")
        self.unhide_btn.setVisible(len(self.hidden_mgr.hidden) > 0)

    def _on_select(self, row):
        if self._select_mode or row < 0 or row >= len(self.filtered_channels):
            return
        url = self.filtered_channels[row].url
        self._pending_url = url
        self.video.stop_play()
        self._switch_timer.start()

    def _do_play(self):
        if self._pending_url:
            url = self._pending_url
            self._pending_url = None
            self.video.play_url(url)

    def _toggle_fav(self):
        self._show_fav_only = self.fav_btn.isChecked()
        self.fav_btn.setText("全部" if self._show_fav_only else "收藏")
        self._filter()

    def _toggle_select_mode(self):
        self._select_mode = self.select_btn.isChecked()
        self.select_btn.setText("退出选择" if self._select_mode else "批量选择")
        self.batch_hide_btn.setVisible(self._select_mode)
        self.select_all_btn.setVisible(self._select_mode)
        self.ch_list.setSelectionMode(
            QListWidget.MultiSelection if self._select_mode else QListWidget.SingleSelection
        )
        if not self._select_mode:
            self.ch_list.clearSelection()

    def _select_all(self):
        self.ch_list.selectAll()

    def _batch_hide(self):
        selected = self.ch_list.selectedItems()
        if not selected:
            return
        urls = []
        for item in selected:
            row = self.ch_list.row(item)
            if 0 <= row < len(self.filtered_channels):
                urls.append(self.filtered_channels[row].url)
        if urls:
            reply = QMessageBox.question(
                self, "确认", f"隐藏 {len(urls)} 个频道?",
                QMessageBox.Yes | QMessageBox.No
            )
            if reply == QMessageBox.Yes:
                self.hidden_mgr.hide_batch(urls)
                self._filter()

    def _unhide_all(self):
        hidden_urls = list(self.hidden_mgr.hidden)
        if not hidden_urls:
            return

        hidden_channels = []
        for ch in self.channels:
            if ch.url in hidden_urls:
                hidden_channels.append(ch)

        dialog = QDialog(self)
        dialog.setWindowTitle("恢复隐藏频道")
        dialog.setMinimumWidth(400)
        dialog.setMinimumHeight(400)
        dialog.setStyleSheet(DARK_QSS)

        layout = QVBoxLayout(dialog)

        tip = QLabel(f"共 {len(hidden_channels)} 个隐藏频道，勾选要恢复的:")
        tip.setStyleSheet("color:#aaa;font-size:12px;padding:5px;")
        layout.addWidget(tip)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet("background:#252526;border:1px solid #3c3c3c;")

        container = QWidget()
        container_layout = QVBoxLayout(container)
        container_layout.setContentsMargins(5, 5, 5, 5)
        container_layout.setSpacing(2)

        checkboxes = []
        for ch in hidden_channels:
            cb = QCheckBox(ch.name)
            cb.channel_url = ch.url
            cb.setStyleSheet("color:#e0e0e0;font-size:13px;padding:4px;")
            checkboxes.append(cb)
            container_layout.addWidget(cb)
        container_layout.addStretch()

        scroll.setWidget(container)
        layout.addWidget(scroll, 1)

        btn_layout = QHBoxLayout()
        select_all_btn = QPushButton("全选")
        select_all_btn.clicked.connect(lambda: [cb.setChecked(True) for cb in checkboxes])
        btn_layout.addWidget(select_all_btn)

        deselect_all_btn = QPushButton("全不选")
        deselect_all_btn.clicked.connect(lambda: [cb.setChecked(False) for cb in checkboxes])
        btn_layout.addWidget(deselect_all_btn)
        layout.addLayout(btn_layout)

        ok_btn = QPushButton("恢复选中")
        ok_btn.clicked.connect(dialog.accept)
        cancel_btn = QPushButton("取消")
        cancel_btn.clicked.connect(dialog.reject)
        btn_layout2 = QHBoxLayout()
        btn_layout2.addWidget(ok_btn)
        btn_layout2.addWidget(cancel_btn)
        layout.addLayout(btn_layout2)

        if dialog.exec() == QDialog.Accepted:
            urls_to_show = [cb.channel_url for cb in checkboxes if cb.isChecked()]
            if urls_to_show:
                for url in urls_to_show:
                    self.hidden_mgr.show(url)
                self._filter()

    def _start_speed_test(self):
        if self._tester:
            return
        visible = [ch for ch in self.channels if not self.hidden_mgr.is_hidden(ch.url)]
        if not visible:
            return
        reply = QMessageBox.question(
            self, "测速", f"测试 {len(visible)} 个频道速度，低于2MB/s将隐藏?\n需要一些时间...",
            QMessageBox.Yes | QMessageBox.No
        )
        if reply != QMessageBox.Yes:
            return
        self._tester = SpeedTester(visible)
        self.speed_test_btn.setEnabled(False)
        self.refresh_btn.setEnabled(False)
        self.switch_btn.setEnabled(False)
        self.progress.setMaximum(0)
        self.progress.show()
        self.video.show_msg("测速中...")
        self._tester.start()
        self._poll_tester()

    def _poll_tester(self):
        if self._tester and not self._tester.is_alive():
            slow_urls = self._tester.slow_urls
            self._tester = None
            self.speed_test_btn.setEnabled(True)
            self.refresh_btn.setEnabled(True)
            self.switch_btn.setEnabled(True)
            self.progress.hide()
            self.progress.setMaximum(0)
            self.video.hide_msg()
            if slow_urls:
                self.hidden_mgr.hide_batch(slow_urls)
                self._filter()
                self.status_label.setText(f"已隐藏 {len(slow_urls)} 个慢频道")
            else:
                self.status_label.setText("所有频道速度正常")
            QTimer.singleShot(3000, lambda: self.status_label.setText(""))
        elif self._tester:
            QTimer.singleShot(300, self._poll_tester)

    def _ctx_menu(self, pos):
        item = self.ch_list.itemAt(pos)
        if not item:
            return
        row = self.ch_list.row(item)
        if row < 0 or row >= len(self.filtered_channels):
            return
        ch = self.filtered_channels[row]
        menu = QMenu(self)
        if self.fav_mgr.is_favorite(ch.url):
            menu.addAction("取消收藏", lambda: (self.fav_mgr.remove(ch.url), self._filter()))
        else:
            menu.addAction("添加收藏", lambda: (self.fav_mgr.add(ch), self._filter()))
        menu.addSeparator()
        menu.addAction("复制地址", lambda: (QApplication.clipboard().setText(ch.url), self.video.show_msg("已复制"), QTimer.singleShot(1000, self.video.hide_msg)))
        menu.addSeparator()
        menu.addAction("隐藏频道", lambda: (self.hidden_mgr.hide(ch.url), self._filter()))
        menu.exec_(self.ch_list.mapToGlobal(pos))

    def keyPressEvent(self, e):
        k = e.key()
        if k == Qt.Key_Left:
            self._volume = max(0, self._volume - 15)
            self.video.set_volume(self._volume)
        elif k == Qt.Key_Right:
            self._volume = min(100, self._volume + 15)
            self.video.set_volume(self._volume)
        elif k == Qt.Key_Space:
            self.video.toggle_pause()
        elif k == Qt.Key_F5:
            self._refresh()
        elif k == Qt.Key_F:
            self.search.setFocus()
        else:
            super().keyPressEvent(e)

    def closeEvent(self, e):
        if self._loader:
            self._loader.stop()
        if self._tester:
            self._tester.stop()
        self.video.close()
        super().closeEvent(e)

if __name__ == "__main__":
    app = QApplication(sys.argv)
    app.setApplicationName("TV Player Pro")
    app.setFont(QFont("Microsoft YaHei UI", 10))
    w = MainWindow()
    w.show()
    sys.exit(app.exec())
