#!/usr/bin/env python3
"""
多重扫描 + 合并 + 剔除失效源/线路
Pass 0: 下载并合并所有预置源
Pass 1: HTTP 快速预筛（HEAD/Range GET）
Pass 2: FFprobe 可播验证
Pass 3: 速度复检 + 再剔除慢/死线
全程显示进度条：已处理 / 剩余 / 百分比
"""

from __future__ import annotations

import json
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

# ── 路径 ──────────────────────────────────────────────
BASE = Path(r"C:\Users\96335\Desktop\TVPlayer")
MIRRORS = BASE / "iptv-mirrors"
IOS_RES = BASE / "TVPlayer-iOS" / "TVPlayer_iOS" / "Resources"
IOS_SCRIPTS = BASE / "TVPlayer-iOS" / "scripts"

# ── 预置远程源 ────────────────────────────────────────
REMOTE_SOURCES = [
    ("Validated GitHub", "https://raw.githubusercontent.com/wfygefjgd/live-player/main/iptv-mirrors/validated-channels.m3u"),
    ("Validated jsDelivr", "https://cdn.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u"),
    ("Guovin result", "https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u"),
    ("vbskycn iptv4", "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u"),
    ("fanmingming ipv6", "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"),
    ("BurningC4", "https://wfygefjgd.github.io/live-player/iptv-mirrors/burningc4-chinese-iptv.m3u"),
    ("zbefine", "https://wfygefjgd.github.io/live-player/iptv-mirrors/zbefine-iptv.m3u"),
    ("suxuang", "https://wfygefjgd.github.io/live-player/iptv-mirrors/suxuang-myiptv.m3u"),
]

LOCAL_JSON = [
    MIRRORS / "validated-channels.json",
    MIRRORS / "optimized-channels.json",
    MIRRORS / "merged-all-sources.json",
    IOS_RES / "validated-channels.json",
    IOS_SCRIPTS / "validated-channels.json",
]

LOCAL_M3U = [
    MIRRORS / "burningc4-chinese-iptv.m3u",
    MIRRORS / "zbefine-iptv.m3u",
    MIRRORS / "suxuang-myiptv.m3u",
    MIRRORS / "optimized-channels.m3u",
    MIRRORS / "validated-channels.m3u",
]

# ── 扫描参数 ──────────────────────────────────────────
HTTP_TIMEOUT = 4.0
HTTP_WORKERS = 40
FFPROBE_TIMEOUT = 6
FFPROBE_WORKERS = 12
SPEED_TIMEOUT = 5.0
SPEED_WORKERS = 30
MAX_MS = 4500                 # 超过则剔除
MAX_URLS_PER_CHANNEL = 6      # 每台最多保留线路
MIN_URLS = 1
USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def log(msg: str = "") -> None:
    print(msg, flush=True)


def progress_bar(current: int, total: int, prefix: str = "", extra: str = "", width: int = 36) -> None:
    if total <= 0:
        return
    pct = current / total
    filled = int(width * pct)
    bar = "#" * filled + "-" * (width - filled)
    remain = max(0, total - current)
    line = f"\r{prefix} [{bar}] {current}/{total} 已处理  剩余{remain}  ({pct*100:5.1f}%)"
    if extra:
        line += f"  {extra}"
    sys.stdout.write(line)
    sys.stdout.flush()
    if current >= total:
        print(flush=True)


def normalize_name(name: str) -> str:
    w = name.lower().strip()
    m = re.search(r"cctv\s*[-_ ]*0*(\d+)(k|\+)?", w)
    if m:
        num = m.group(1)
        suffix = (m.group(2) or "").upper()
        return f"cctv{num}{suffix}"
    w = re.sub(r"[\s\-—_.·.,，、。/\\|()（）\[\]【】:：]+", "", w)
    w = re.sub(r"(高清|超清|标清|蓝光|流畅|频道|直播|在线|测试|备用\d*|线路\d+|源\d+|综合|台)$", "", w)
    w = re.sub(r"(中央|央视)", "cctv", w)
    return w or name.strip().lower()


def parse_m3u_text(content: str, source: str) -> list[dict]:
    channels: list[dict] = []
    name = None
    group = "未分组"
    for raw in content.splitlines():
        line = raw.strip()
        if line.startswith("#EXTINF"):
            group = "未分组"
            gm = re.search(r'group-title="([^"]*)"', line)
            if gm:
                group = gm.group(1).strip() or "未分组"
            nm = re.search(r'tvg-name="([^"]+)"', line)
            if nm:
                name = nm.group(1).strip()
            elif "," in line:
                name = line.split(",", 1)[1].strip()
            else:
                name = None
        elif line and not line.startswith("#") and name:
            channels.append({"name": name, "group": group, "urls": [line], "source": source})
            name = None
            group = "未分组"
    return channels


def load_json_file(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        log(f"  跳过 JSON {path.name}: {e}")
        return []
    items = data.get("channels", data) if isinstance(data, dict) else data
    if not isinstance(items, list):
        return []
    out = []
    for ch in items:
        if not isinstance(ch, dict):
            continue
        name = str(ch.get("name", "")).strip()
        group = str(ch.get("group", "未分组")).strip() or "未分组"
        urls = [str(u).strip() for u in ch.get("urls", []) if str(u).strip()]
        if name and urls:
            out.append({"name": name, "group": group, "urls": urls, "source": path.name})
    return out


def download_m3u(url: str, timeout: int = 25) -> str | None:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as resp:
            raw = resp.read()
        for enc in ("utf-8", "gbk", "latin-1"):
            try:
                return raw.decode(enc)
            except Exception:
                continue
        return raw.decode("utf-8", errors="replace")
    except Exception as e:
        log(f"  下载失败: {e}")
        return None


def merge_channels(items: list[dict]) -> list[dict]:
    merged: OrderedDict[str, dict] = OrderedDict()
    for ch in items:
        key = normalize_name(ch["name"])
        if key not in merged:
            merged[key] = {
                "name": ch["name"],
                "group": ch.get("group") or "未分组",
                "urls": [],
                "_seen": set(),
            }
        bucket = merged[key]
        if bucket["group"] in ("未分组", "其他", "") and ch.get("group"):
            bucket["group"] = ch["group"]
        for u in ch.get("urls", []):
            u = u.strip()
            if not u or u in bucket["_seen"]:
                continue
            bucket["_seen"].add(u)
            bucket["urls"].append(u)
    result = []
    for v in merged.values():
        v.pop("_seen", None)
        if v["urls"]:
            result.append(v)
    return result


def http_probe(url: str) -> bool:
    headers = {"User-Agent": USER_AGENT, "Accept": "*/*"}
    # HEAD
    try:
        req = urllib.request.Request(url, method="HEAD", headers=headers)
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT, context=SSL_CTX) as resp:
            code = resp.getcode()
            if 200 <= code < 400:
                return True
    except urllib.error.HTTPError as e:
        if e.code in (200, 206, 301, 302, 307, 308, 405):
            # 405 再试 GET
            pass
        elif e.code >= 400 and e.code not in (405, 403):
            return False
    except Exception:
        pass
    # Range GET
    try:
        h = dict(headers)
        h["Range"] = "bytes=0-1023"
        req = urllib.request.Request(url, headers=h)
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT, context=SSL_CTX) as resp:
            code = resp.getcode()
            data = resp.read(256)
            return (200 <= code < 400) and len(data) > 0
    except urllib.error.HTTPError as e:
        return e.code in (200, 206)
    except Exception:
        return False


def ffprobe_ok(url: str) -> bool:
    cmd = [
        "ffprobe",
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=codec_type",
        "-of", "default=noprint_wrappers=1:nokey=1",
        "-timeout", str(int(FFPROBE_TIMEOUT * 1_000_000)),
        "-user_agent", USER_AGENT,
        url,
    ]
    try:
        r = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=FFPROBE_TIMEOUT + 2,
            text=True,
        )
        return r.returncode == 0 and "video" in (r.stdout or "").lower()
    except Exception:
        return False


def speed_probe(url: str) -> tuple[bool, float]:
    """返回 (可用, 毫秒)"""
    start = time.time()
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": USER_AGENT, "Accept": "*/*", "Range": "bytes=0-2047"},
        )
        with urllib.request.urlopen(req, timeout=SPEED_TIMEOUT, context=SSL_CTX) as resp:
            data = resp.read(512)
            ms = (time.time() - start) * 1000
            ok = resp.getcode() in range(200, 400) and len(data) > 0 and ms <= MAX_MS
            return ok, ms
    except Exception:
        return False, (time.time() - start) * 1000


def unique_urls(channels: list[dict]) -> list[str]:
    seen = set()
    out = []
    for ch in channels:
        for u in ch["urls"]:
            if u not in seen:
                seen.add(u)
                out.append(u)
    return out


def filter_by_url_set(channels: list[dict], good: set[str]) -> list[dict]:
    out = []
    for ch in channels:
        urls = [u for u in ch["urls"] if u in good]
        if len(urls) >= MIN_URLS:
            out.append({"name": ch["name"], "group": ch.get("group", "未分组"), "urls": urls})
    return out


def pass_http(channels: list[dict]) -> list[dict]:
    urls = unique_urls(channels)
    total = len(urls)
    log(f"\n[Pass 1] HTTP 快速预筛  线路={total}  并发={HTTP_WORKERS}  超时={HTTP_TIMEOUT}s")
    good: set[str] = set()
    done = 0
    ok_n = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=HTTP_WORKERS) as ex:
        futs = {ex.submit(http_probe, u): u for u in urls}
        for fut in as_completed(futs):
            u = futs[fut]
            done += 1
            try:
                if fut.result():
                    good.add(u)
                    ok_n += 1
            except Exception:
                pass
            if done % 5 == 0 or done == total:
                rate = done / max(time.time() - t0, 0.01)
                eta = (total - done) / max(rate, 0.01)
                progress_bar(done, total, "HTTP", extra=f"有效{ok_n} ETA{eta:.0f}s")
    filtered = filter_by_url_set(channels, good)
    log(f"  结果: 线路 {ok_n}/{total} 有效 | 频道 {len(filtered)}/{len(channels)}")
    return filtered


def pass_ffprobe(channels: list[dict]) -> list[dict]:
    urls = unique_urls(channels)
    total = len(urls)
    log(f"\n[Pass 2] FFprobe 可播验证  线路={total}  并发={FFPROBE_WORKERS}  超时={FFPROBE_TIMEOUT}s")
    if total == 0:
        return []
    good: set[str] = set()
    done = 0
    ok_n = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=FFPROBE_WORKERS) as ex:
        futs = {ex.submit(ffprobe_ok, u): u for u in urls}
        for fut in as_completed(futs):
            u = futs[fut]
            done += 1
            try:
                if fut.result():
                    good.add(u)
                    ok_n += 1
            except Exception:
                pass
            if done % 2 == 0 or done == total:
                rate = done / max(time.time() - t0, 0.01)
                eta = (total - done) / max(rate, 0.01)
                progress_bar(done, total, "FFprobe", extra=f"可播{ok_n} ETA{eta:.0f}s")
    filtered = filter_by_url_set(channels, good)
    log(f"  结果: 线路 {ok_n}/{total} 可播 | 频道 {len(filtered)}/{len(channels)}")
    return filtered


def pass_speed(channels: list[dict]) -> list[dict]:
    urls = unique_urls(channels)
    total = len(urls)
    log(f"\n[Pass 3] 速度复检+再剔除  线路={total}  并发={SPEED_WORKERS}  上限={MAX_MS}ms")
    if total == 0:
        return []
    scores: dict[str, float] = {}
    good: set[str] = set()
    done = 0
    ok_n = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=SPEED_WORKERS) as ex:
        futs = {ex.submit(speed_probe, u): u for u in urls}
        for fut in as_completed(futs):
            u = futs[fut]
            done += 1
            try:
                ok, ms = fut.result()
                if ok:
                    good.add(u)
                    scores[u] = ms
                    ok_n += 1
            except Exception:
                pass
            if done % 3 == 0 or done == total:
                rate = done / max(time.time() - t0, 0.01)
                eta = (total - done) / max(rate, 0.01)
                progress_bar(done, total, "Speed", extra=f"快线{ok_n} ETA{eta:.0f}s")

    # 按速度排序，每台最多 MAX_URLS_PER_CHANNEL
    out = []
    for ch in channels:
        ranked = sorted(
            [u for u in ch["urls"] if u in good],
            key=lambda x: scores.get(x, 99999),
        )[:MAX_URLS_PER_CHANNEL]
        if ranked:
            out.append({"name": ch["name"], "group": ch.get("group", "未分组"), "urls": ranked})
    log(f"  结果: 线路 {sum(len(c['urls']) for c in out)}/{total} | 频道 {len(out)}/{len(channels)}")
    return out


def save_outputs(channels: list[dict], meta_extra: dict) -> None:
    total_urls = sum(len(c["urls"]) for c in channels)
    now = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")
    payload = {
        "metadata": {
            "total_channels": len(channels),
            "valid_channels": len(channels),
            "total_urls_tested": meta_extra.get("tested", total_urls),
            "total_valid_urls": total_urls,
            "validated_at": now,
            "max_urls_per_channel": MAX_URLS_PER_CHANNEL,
            "sources": meta_extra.get("sources", []),
            "passes": meta_extra.get("passes", []),
        },
        "channels": channels,
    }

    targets_json = [
        MIRRORS / "validated-channels.json",
        MIRRORS / "optimized-channels.json",
        MIRRORS / "multi-pass-filtered.json",
        IOS_RES / "validated-channels.json",
        IOS_SCRIPTS / "validated-channels.json",
    ]
    targets_m3u = [
        MIRRORS / "validated-channels.m3u",
        MIRRORS / "optimized-channels.m3u",
        MIRRORS / "multi-pass-filtered.m3u",
    ]

    text = json.dumps(payload, ensure_ascii=False, indent=2)
    for p in targets_json:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        log(f"  写入 {p}")

    m3u_lines = ["#EXTM3U"]
    for ch in channels:
        for url in ch["urls"]:
            m3u_lines.append(f'#EXTINF:-1 group-title="{ch["group"]}",{ch["name"]}')
            m3u_lines.append(url)
    m3u_text = "\n".join(m3u_lines) + "\n"
    for p in targets_m3u:
        p.write_text(m3u_text, encoding="utf-8")
        log(f"  写入 {p}")


def collect_all() -> tuple[list[dict], list[str]]:
    log("\n[Pass 0] 扫描与合并数据来源")
    all_items: list[dict] = []
    source_names: list[str] = []
    dead_sources: list[str] = []

    # 远程
    n = len(REMOTE_SOURCES)
    for i, (name, url) in enumerate(REMOTE_SOURCES, 1):
        progress_bar(i - 1, n, "下载源", extra=name[:24])
        log(f"\n  [{i}/{n}] {name}")
        log(f"    {url}")
        body = download_m3u(url)
        if not body or "#EXT" not in body[:2000]:
            log("    -> 失效，剔除该源")
            dead_sources.append(name)
            continue
        parsed = parse_m3u_text(body, name)
        log(f"    -> {len(parsed)} 条目")
        if not parsed:
            dead_sources.append(name)
            continue
        all_items.extend(parsed)
        source_names.append(name)
    progress_bar(n, n, "下载源", extra="完成")

    # 本地 JSON
    for path in LOCAL_JSON:
        if not path.exists():
            continue
        log(f"  本地 JSON: {path.name}")
        items = load_json_file(path)
        log(f"    -> {len(items)} 频道")
        if items:
            all_items.extend(items)
            source_names.append(path.name)

    # 本地 M3U
    for path in LOCAL_M3U:
        if not path.exists():
            continue
        log(f"  本地 M3U: {path.name}")
        try:
            items = parse_m3u_text(path.read_text(encoding="utf-8", errors="replace"), path.name)
        except Exception as e:
            log(f"    失败: {e}")
            continue
        log(f"    -> {len(items)} 条目")
        if items:
            all_items.extend(items)
            source_names.append(path.name)

    log(f"\n  原始条目: {len(all_items)}")
    if dead_sources:
        log(f"  已剔除失效远程源: {', '.join(dead_sources)}")

    merged = merge_channels(all_items)
    url_n = sum(len(c["urls"]) for c in merged)
    log(f"  合并后: {len(merged)} 频道 / {url_n} 线路")

    # 保存合并中间结果
    mid = {
        "metadata": {
            "total_channels": len(merged),
            "total_urls": url_n,
            "merged_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "sources": source_names,
            "dead_sources": dead_sources,
        },
        "channels": merged,
    }
    (MIRRORS / "merged-all-sources.json").write_text(
        json.dumps(mid, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    log(f"  中间文件: merged-all-sources.json")
    return merged, source_names


def main() -> int:
    t_all = time.time()
    log("=" * 68)
    log("TVPlayer 多重扫描筛选  (合并 → HTTP → FFprobe → 速度)")
    log("=" * 68)

    # 检查 ffprobe
    try:
        subprocess.run(["ffprobe", "-version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        log("[OK] ffprobe 可用")
    except Exception:
        log("[错误] 需要 ffprobe（ffmpeg）")
        return 1

    merged, sources = collect_all()
    if not merged:
        log("无数据可处理")
        return 1

    tested0 = sum(len(c["urls"]) for c in merged)
    passes = []

    p1 = pass_http(merged)
    passes.append({"name": "http", "channels": len(p1), "urls": sum(len(c["urls"]) for c in p1)})
    if not p1:
        log("Pass1 后无可用频道，终止")
        return 1

    p2 = pass_ffprobe(p1)
    passes.append({"name": "ffprobe", "channels": len(p2), "urls": sum(len(c["urls"]) for c in p2)})
    # 若 FFprobe 过严导致过少，回退用 HTTP 结果再做速度筛
    base = p2 if len(p2) >= 30 else p1
    if base is p1 and len(p2) < 30:
        log(f"  注意: FFprobe 仅 {len(p2)} 台，改用 HTTP 结果进入 Pass3（仍会再剔除）")

    p3 = pass_speed(base)
    passes.append({"name": "speed", "channels": len(p3), "urls": sum(len(c["urls"]) for c in p3)})

    # 若仍过多低质量，再强制只保留有多线或头部央视/卫视关键词的策略：直接用 p3
    final = p3 if p3 else base
    if len(final) < 20 and p1:
        log("  最终过少，放宽为 HTTP 通过集 + 每台最多 3 线")
        final = []
        for ch in p1:
            urls = ch["urls"][:3]
            if urls:
                final.append({"name": ch["name"], "group": ch.get("group", "未分组"), "urls": urls})

    log("\n[输出] 写入 validated / optimized / iOS Resources")
    save_outputs(
        final,
        {
            "tested": tested0,
            "sources": sources,
            "passes": passes,
        },
    )

    elapsed = time.time() - t_all
    log("\n" + "=" * 68)
    log("完成")
    log(f"  输入: {len(merged)} 台 / {tested0} 线")
    log(f"  输出: {len(final)} 台 / {sum(len(c['urls']) for c in final)} 线")
    for p in passes:
        log(f"  - {p['name']}: {p['channels']} 台 / {p['urls']} 线")
    log(f"  耗时: {elapsed/60:.1f} 分钟")
    log("=" * 68)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
