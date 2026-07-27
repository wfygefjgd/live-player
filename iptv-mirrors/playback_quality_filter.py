#!/usr/bin/env python3
"""
真实可播筛选（换方案）：
1) 合并多源 + 去垃圾台
2) 轻量连通预筛（仅丢掉明显死链）
3) ffmpeg 真实拉流解码：必须出视频帧，且码率/卡顿达标
4) 央视/卫视保底优先，输出 validated-channels

进度：已处理 / 剩余 / 百分比
"""

from __future__ import annotations

import json
import re
import ssl
import subprocess
import sys
import time
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

BASE = Path(r"C:\Users\96335\Desktop\TVPlayer")
MIRRORS = BASE / "iptv-mirrors"
IOS_RES = BASE / "TVPlayer-iOS" / "TVPlayer_iOS" / "Resources"
IOS_SCRIPTS = BASE / "TVPlayer-iOS" / "scripts"

# 输入优先 multi-pass 全量，否则合并本地
INPUT_CANDIDATES = [
    MIRRORS / "multi-pass-filtered.json",
    MIRRORS / "merged-all-sources.json",
    MIRRORS / "validated-channels.json",
]

REMOTE_M3U = [
    ("Guovin", "https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u"),
    ("vbskycn", "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u"),
    ("fanmingming", "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"),
]

LOCAL_M3U = [
    MIRRORS / "burningc4-chinese-iptv.m3u",
    MIRRORS / "zbefine-iptv.m3u",
    MIRRORS / "suxuang-myiptv.m3u",
]

# ── 真实播放阈值 ──────────────────────────────────
FF_SECONDS = 6                 # 连续拉流秒数
FF_TIMEOUT = 12                # 进程总超时
MIN_VIDEO_FRAMES = 20          # 至少解出的视频帧（约 4s@5fps 也够）
MIN_SIZE_KB = 40               # 至少拉到的数据量
MIN_BITRATE_KBPS = 150         # 平均码率下限（kbps，直播波动大）
MAX_URLS_PER_CH = 4            # 每台最多保留 4 条可用线
PRECHECK_WORKERS = 36
FF_WORKERS = 6                 # ffmpeg 并发低一些，减少假失败
PRECHECK_TIMEOUT = 3.5
TARGET_CHANNELS = 160
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

JUNK_RE = re.compile(
    r"(付费|购物|测试|样片|not\s*24|预告|广播|音频|radio|fm\d|春晚|"
    r"billiards|golf|storm\s|culture of|health\b|nostalgia|women.?s fashion|"
    r"weapon|world geography|第一剧场|怀旧|cctv\+|8k)",
    re.I,
)


def log(msg: str = "") -> None:
    print(msg, flush=True)


def progress(cur: int, total: int, prefix: str, extra: str = "", width: int = 34) -> None:
    if total <= 0:
        return
    pct = cur / total
    bar = "#" * int(width * pct) + "-" * (width - int(width * pct))
    rem = max(0, total - cur)
    sys.stdout.write(f"\r{prefix} [{bar}] {cur}/{total} 已处理 剩余{rem} ({pct*100:5.1f}%)" + (f" {extra}" if extra else ""))
    sys.stdout.flush()
    if cur >= total:
        print(flush=True)


def norm_key(name: str) -> str:
    w = name.lower().strip()
    m = re.search(r"cctv\s*[-_ ]*0*(\d+)(\+)?", w)
    if m:
        return f"cctv{m.group(1)}{m.group(2) or ''}"
    w = re.sub(r"[\s\-—_.·.,，、/\\| sp()（）\[\]【】:：]+", "", w)
    w = re.sub(r"(高清|超清|标清|蓝光|流畅|频道|直播|在线|\d+p|1080p|720p|4k)$", "", w, flags=re.I)
    return w or name.strip().lower()


def is_flagship(name: str, group: str = "") -> bool:
    n, g = name, group or ""
    if JUNK_RE.search(n) or JUNK_RE.search(g):
        return False
    if re.search(r"cctv[-_ ]?(?:0?[1-9]|1[0-7]|5\+|16)(?:\D|$)", n, re.I):
        return True
    if "卫视" in n or "卫视" in g:
        return True
    if re.search(r"(凤凰|翡翠|明珠)", n):
        return True
    return False


def parse_m3u(text: str, source: str) -> list[dict]:
    out = []
    name, group = None, "未分组"
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("#EXTINF"):
            gm = re.search(r'group-title="([^"]*)"', line)
            group = (gm.group(1).strip() if gm else "未分组") or "未分组"
            name = line.split(",", 1)[1].strip() if "," in line else None
        elif line and not line.startswith("#") and name:
            out.append({"name": name, "group": group, "urls": [line], "source": source})
            name, group = None, "未分组"
    return out


def load_json(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    items = data.get("channels", data) if isinstance(data, dict) else data
    out = []
    for ch in items or []:
        if not isinstance(ch, dict):
            continue
        name = str(ch.get("name", "")).strip()
        urls = [str(u).strip() for u in ch.get("urls", []) if str(u).strip()]
        if name and urls:
            out.append({"name": name, "group": str(ch.get("group", "未分组")), "urls": urls, "source": path.name})
    return out


def download(url: str, timeout: int = 25) -> str | None:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as r:
            return r.read().decode("utf-8", errors="replace")
    except Exception as e:
        log(f"  下载失败 {url}: {e}")
        return None


def merge(items: list[dict]) -> list[dict]:
    m: OrderedDict[str, dict] = OrderedDict()
    for ch in items:
        if JUNK_RE.search(ch["name"]) or JUNK_RE.search(ch.get("group", "")):
            continue
        key = norm_key(ch["name"])
        if key not in m:
            m[key] = {"name": ch["name"], "group": ch.get("group") or "未分组", "urls": [], "_s": set()}
        b = m[key]
        if b["group"] in ("未分组", "其他", "") and ch.get("group"):
            b["group"] = ch["group"]
        for u in ch["urls"]:
            u = u.strip()
            if u and u not in b["_s"]:
                b["_s"].add(u)
                b["urls"].append(u)
    out = []
    for v in m.values():
        v.pop("_s", None)
        if v["urls"]:
            out.append(v)
    return out


def precheck(url: str) -> bool:
    """只丢掉明显死链；宽松，避免误杀。"""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Range": "bytes=0-2047"})
        with urllib.request.urlopen(req, timeout=PRECHECK_TIMEOUT, context=SSL_CTX) as r:
            data = r.read(512)
            code = r.getcode()
            return 200 <= code < 400 and len(data) > 0
    except Exception:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=PRECHECK_TIMEOUT, context=SSL_CTX) as r:
                return 200 <= r.getcode() < 400
        except Exception:
            return False


def ffmpeg_play_score(url: str) -> dict:
    """
    真实拉流：ffmpeg 读 FF_SECONDS 秒，统计帧/体积。
    Windows 下 ffmpeg 进度用 \\r 刷新，必须按二进制读再把 \\r 当换行。
    """
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "info",
        "-stats",
        "-user_agent", UA,
        "-rw_timeout", "8000000",
        "-reconnect", "1",
        "-reconnect_streamed", "1",
        "-reconnect_delay_max", "2",
        "-i", url,
        "-t", str(FF_SECONDS),
        "-map", "0:v:0?",
        "-c", "copy",
        "-f", "null",
        "-",
    ]
    t0 = time.time()
    try:
        r = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=FF_TIMEOUT,
        )
        raw = r.stderr or b""
        err = raw.decode("utf-8", errors="replace").replace("\r", "\n")
        frames = 0
        for mm in re.finditer(r"frame=\s*(\d+)", err):
            frames = max(frames, int(mm.group(1)))
        size_kb = 0.0
        mm = re.search(r"video:\s*([\d.]+)\s*Ki?B", err, re.I)
        if mm:
            size_kb = float(mm.group(1))
        else:
            mm = re.search(r"(?:L?size|size)=\s*([\d.]+)\s*Ki?B", err, re.I)
            if mm:
                size_kb = float(mm.group(1))
        play_t = float(FF_SECONDS)
        tm = re.search(r"time=(\d+):(\d+):(\d+(?:\.\d+)?)", err)
        if tm:
            play_t = max(0.3, int(tm.group(1)) * 3600 + int(tm.group(2)) * 60 + float(tm.group(3)))
        bitrate = (size_kb * 8) / play_t if play_t > 0 else 0
        # 可播：真正拉到视频数据
        ok = frames >= 8 or size_kb >= 20
        # 流畅：帧/体积足够
        smooth = (frames >= MIN_VIDEO_FRAMES or size_kb >= MIN_SIZE_KB) and size_kb >= MIN_SIZE_KB * 0.4
        if smooth and bitrate < MIN_BITRATE_KBPS * 0.3 and size_kb < MIN_SIZE_KB:
            smooth = False
        score = 0.0
        if smooth:
            score = min(100.0, bitrate / 15 + frames / 3 + size_kb / 20)
        elif ok:
            score = min(65.0, bitrate / 25 + max(frames, 1) / 6 + size_kb / 50)
        elapsed = time.time() - t0
        return {
            "url": url,
            "ok": smooth,
            "weak_ok": ok,
            "frames": frames,
            "size_kb": round(size_kb, 1),
            "bitrate_kbps": round(bitrate, 1),
            "score": round(score, 1),
            "elapsed": round(elapsed, 2),
        }
    except subprocess.TimeoutExpired:
        return {"url": url, "ok": False, "weak_ok": False, "frames": 0, "size_kb": 0, "bitrate_kbps": 0, "score": 0, "elapsed": FF_TIMEOUT}
    except Exception:
        return {"url": url, "ok": False, "weak_ok": False, "frames": 0, "size_kb": 0, "bitrate_kbps": 0, "score": 0, "elapsed": 0}


def normalize_group(name: str, group: str) -> str:
    n, g = name, group or ""
    if re.search(r"cctv|央视", n, re.I) or "央视" in g:
        return "央视"
    if "卫视" in n or "卫视" in g:
        return "卫视"
    if re.search(r"体育|足球|NBA|CBA", n, re.I):
        return "体育"
    if re.search(r"香港|澳门|台湾|凤凰|翡翠|明珠", n) or "港澳" in g:
        return "港澳台"
    if re.search(r"CGTN|国际|CNN|BBC|NHK", n, re.I) or "国际" in g:
        return "国际"
    if "地方" in g:
        return "地方"
    return g if g not in ("", "未分组", "其他") else "其他"


def collect() -> tuple[list[dict], list[str]]:
    items: list[dict] = []
    sources: list[str] = []
    for p in INPUT_CANDIDATES:
        if p.exists():
            log(f"  加载 {p.name}")
            chs = load_json(p)
            log(f"    -> {len(chs)}")
            items.extend(chs)
            sources.append(p.name)
            break  # 只用最新一份全量，避免重复
    for p in LOCAL_M3U:
        if p.exists():
            chs = parse_m3u(p.read_text(encoding="utf-8", errors="replace"), p.name)
            log(f"  本地 {p.name}: {len(chs)}")
            items.extend(chs)
            sources.append(p.name)
    # 远程补充（失败忽略）
    for name, url in REMOTE_M3U:
        body = download(url)
        if body and "#EXT" in body[:2000]:
            chs = parse_m3u(body, name)
            log(f"  远程 {name}: {len(chs)}")
            items.extend(chs)
            sources.append(name)
        else:
            log(f"  远程失效: {name}")
    merged = merge(items)
    log(f"  合并后 {len(merged)} 台 / {sum(len(c['urls']) for c in merged)} 线")
    return merged, sources


def main() -> int:
    log("=" * 66)
    log("真实可播筛选 (ffmpeg 解码 + 码率)")
    log("=" * 66)
    try:
        subprocess.run(["ffmpeg", "-version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    except Exception:
        log("需要 ffmpeg")
        return 1

    log("\n[1/4] 合并来源")
    channels, sources = collect()
    if not channels:
        return 1

    # 旗舰优先测更多线
    url_jobs: list[tuple[str, str, bool]] = []  # url, chkey, flagship
    ch_map = {norm_key(c["name"]): c for c in channels}
    for c in channels:
        key = norm_key(c["name"])
        flag = is_flagship(c["name"], c.get("group", ""))
        # 多测几条候选，才能筛出每台 4 条好线
        limit = 10 if flag else 8
        for u in c["urls"][:limit]:
            url_jobs.append((u, key, flag))

    # 去重 url
    seen = set()
    uniq_jobs = []
    for u, k, f in url_jobs:
        if u in seen:
            continue
        seen.add(u)
        uniq_jobs.append((u, k, f))

    log(f"\n[2/4] 连通预筛 n={len(uniq_jobs)}")
    alive = set()
    done = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=PRECHECK_WORKERS) as ex:
        futs = {ex.submit(precheck, u): u for u, _, _ in uniq_jobs}
        for fut in as_completed(futs):
            u = futs[fut]
            done += 1
            try:
                if fut.result():
                    alive.add(u)
            except Exception:
                pass
            if done % 5 == 0 or done == len(uniq_jobs):
                rate = done / max(time.time() - t0, 0.01)
                eta = (len(uniq_jobs) - done) / max(rate, 0.01)
                progress(done, len(uniq_jobs), "预筛", f"通{len(alive)} ETA{eta:.0f}s")
    log(f"  连通 {len(alive)}/{len(uniq_jobs)}")

    ff_list = [(u, k, f) for u, k, f in uniq_jobs if u in alive]
    # 旗舰全部测；非旗舰可截断预算
    flag_jobs = [j for j in ff_list if j[2]]
    other_jobs = [j for j in ff_list if not j[2]]
    # 其它线预算放宽，保证非旗舰也能凑满 4 线
    other_jobs = other_jobs[:900]
    ff_list = flag_jobs + other_jobs
    log(f"\n[3/4] ffmpeg 真实拉流 n={len(ff_list)} (旗舰{len(flag_jobs)}+其它{len(other_jobs)})")
    log(f"  条件: ≥{FF_SECONDS}s, 帧≥{MIN_VIDEO_FRAMES} 或 体积≥{MIN_SIZE_KB}kB, 码率≥{MIN_BITRATE_KBPS}kbps")

    metrics: dict[str, dict] = {}
    done = 0
    ok_n = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=FF_WORKERS) as ex:
        futs = {ex.submit(ffmpeg_play_score, u): (u, k) for u, k, _ in ff_list}
        for fut in as_completed(futs):
            u, k = futs[fut]
            done += 1
            try:
                m = fut.result()
            except Exception:
                m = {"url": u, "ok": False, "score": 0}
            metrics[u] = m
            if m.get("ok"):
                ok_n += 1
            if done % 1 == 0 or done == len(ff_list):
                rate = done / max(time.time() - t0, 0.01)
                eta = (len(ff_list) - done) / max(rate, 0.01)
                progress(done, len(ff_list), "解码", f"流畅{ok_n} ETA{eta:.0f}s")
    log(f"  流畅线路 {ok_n}/{len(ff_list)}")

    # 组装频道
    log("\n[4/4] 组装精选列表")
    ranked = []
    for key, ch in ch_map.items():
        lines = []
        for u in ch["urls"]:
            met = metrics.get(u)
            if not met:
                continue
            if met.get("ok"):
                lines.append((met.get("score", 0), met.get("bitrate_kbps", 0), u, "smooth"))
            elif met.get("weak_ok"):
                # 弱可播也保留，分数打折；旗舰权重更高
                boost = 0.7 if is_flagship(ch["name"], ch.get("group", "")) else 0.45
                lines.append((met.get("score", 0) * boost + (8 if met.get("frames", 0) > 0 else 0),
                              met.get("bitrate_kbps", 0), u, "weak"))
        if not lines:
            continue
        lines.sort(key=lambda x: (-x[0], -x[1]))
        # 优先 smooth 线
        smooth_urls = [u for _sc, _br, u, kind in lines if kind == "smooth"]
        weak_urls = [u for _sc, _br, u, kind in lines if kind == "weak"]
        urls = (smooth_urls + weak_urls)[:MAX_URLS_PER_CH]
        if not urls:
            continue
        best = lines[0][0]
        flag = is_flagship(ch["name"], ch.get("group", ""))
        score = best + (15 if flag else 0) + (5 if len(urls) > 1 else 0)
        # 纯弱可播且非旗舰：要求分数别太低
        if not smooth_urls and not flag and best < 12:
            continue
        ranked.append({
            "name": ch["name"],
            "group": normalize_group(ch["name"], ch.get("group", "")),
            "urls": urls,
            "_score": score,
            "_flag": flag,
        })
    ranked.sort(key=lambda x: (-x["_score"], x["name"]))

    # 分组限额 + 旗舰优先
    caps = {"央视": 25, "卫视": 40, "地方": 40, "体育": 12, "港澳台": 15, "国际": 12, "其他": 20}
    final = []
    gcount: dict[str, int] = {}
    ordered = [c for c in ranked if c["_flag"]] + [c for c in ranked if not c["_flag"]]
    for c in ordered:
        g = c["group"]
        cap = caps.get(g, 25)
        if gcount.get(g, 0) >= cap:
            continue
        final.append(c)
        gcount[g] = gcount.get(g, 0) + 1
        if len(final) >= TARGET_CHANNELS:
            break

    out_chs = [{"name": c["name"], "group": c["group"], "urls": c["urls"]} for c in final]
    total_urls = sum(len(c["urls"]) for c in out_chs)
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    payload = {
        "metadata": {
            "total_channels": len(out_chs),
            "valid_channels": len(out_chs),
            "total_valid_urls": total_urls,
            "validated_at": now,
            "max_urls_per_channel": MAX_URLS_PER_CH,
            "filter": "ffmpeg_playback_quality",
            "thresholds": {
                "ff_seconds": FF_SECONDS,
                "min_frames": MIN_VIDEO_FRAMES,
                "min_size_kb": MIN_SIZE_KB,
                "min_bitrate_kbps": MIN_BITRATE_KBPS,
            },
            "sources": sources,
            "group_counts": gcount,
        },
        "channels": out_chs,
    }
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    m3u = ["#EXTM3U"]
    for c in out_chs:
        for u in c["urls"]:
            m3u.append(f'#EXTINF:-1 group-title="{c["group"]}",{c["name"]}')
            m3u.append(u)
    m3u_text = "\n".join(m3u) + "\n"

    targets_json = [
        MIRRORS / "validated-channels.json",
        MIRRORS / "playback-quality-channels.json",
        IOS_RES / "validated-channels.json",
        IOS_SCRIPTS / "validated-channels.json",
    ]
    targets_m3u = [
        MIRRORS / "validated-channels.m3u",
        MIRRORS / "playback-quality-channels.m3u",
    ]
    for p in targets_json:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        log(f"  写 {p}")
    for p in targets_m3u:
        p.write_text(m3u_text, encoding="utf-8")
        log(f"  写 {p}")

    log("\n" + "=" * 66)
    log(f"完成: {len(out_chs)} 台 / {total_urls} 线")
    log(f"分组: {gcount}")
    cctv = sum(1 for c in out_chs if c["group"] == "央视")
    ws = sum(1 for c in out_chs if c["group"] == "卫视")
    log(f"央视 {cctv}  卫视 {ws}")
    log("=" * 66)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
