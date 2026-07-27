#!/usr/bin/env python3
"""
严格质量筛选：在 multi-pass 结果上再砍一轮
1) 频道质量分级（主流 / 普通 / 垃圾）
2) 线路严格复测（TTFB + 拉流字节 + 可选 FFprobe）
3) 按分数排序，限额输出「好台」
进度条：已处理 / 剩余 / 百分比
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
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse

BASE = Path(r"C:\Users\96335\Desktop\TVPlayer")
MIRRORS = BASE / "iptv-mirrors"
IOS_RES = BASE / "TVPlayer-iOS" / "TVPlayer_iOS" / "Resources"
IOS_SCRIPTS = BASE / "TVPlayer-iOS" / "scripts"

# 优先用 multi-pass 全量结果，避免二次严格把输入越筛越少
INPUT = MIRRORS / "multi-pass-filtered.json"
if not INPUT.exists():
    INPUT = MIRRORS / "validated-channels.json"

# ── 严格阈值（主流优先，杂台狠砍）──────────────────
TTFB_MAX = 3.2              # 列表/首包 TTFB 上限（秒）
BYTES_MIN = 1024            # 至少读到的有效字节
SPEED_MIN_KBPS = 200        # 粗测吞吐下限（直播列表本身很小）
PROBE_TIMEOUT = 4.5
WORKERS = 32
FFPROBE_TIMEOUT = 6
FFPROBE_WORKERS = 12
USE_FFPROBE = True          # 对入围线再 ffprobe
MAX_URLS_PER_CH = 3
TARGET_CHANNELS = 180       # 目标台数上限（精选）
MIN_SCORE_KEEP = 50         # 低于此分直接淘汰
REQUIRE_MULTI_LINE_BELOW = 62  # 分数低于此且只有 1 线 → 淘汰（旗舰除外）

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# 垃圾名/分组模式
JUNK_NAME = re.compile(
    r"(付费|购物|电视指南|导视| bo|test|测试|样片|not\s*24|预告|"
    r"billiards|golf\s*&\s*tennis|storm\s*(football|music|theater)|"
    r"culture of quality|health\b|nostalgia|第一剧场|怀旧剧场|"
    r"cctv\+|cctv\s*\+|8k|4k演示|春晚|春晚频道|"
    r"radio|广播|fm\d|am\d|音频)",
    re.I,
)
JUNK_GROUP = re.compile(
    r"(付费|购物|春晚|广播|音频|adult|xxx|色情|赌博)",
    re.I,
)

# 主流加分
CCTV_RE = re.compile(r"^cctv[-_ ]?(\d{1,2}|5\+|4[kK]?|8k?|新闻|少儿|音乐|戏曲|电影|电视剧|纪录|军事|农业|社会|法治)?", re.I)
WEISHI_RE = re.compile(r"(卫视|凤凰|翡翠|明珠|星空|TVB|HOY|VIU)", re.I)
MAJOR_LOCAL = re.compile(
    r"(北京|上海|天津|重庆|湖南|浙江|江苏|东方|广东|深圳|四川|山东|河南|"
    r"湖北|安徽|辽宁|黑龙江|吉林|福建|东南|厦门|河北|山西|陕西|云南|贵州|"
    r"广西|江西|甘肃|青海|宁夏|新疆|西藏|内蒙古|海南|兵团)",
    re.I,
)
SPORTS_RE = re.compile(r"(体育|足球|NBA|CBA|奥运|赛事)", re.I)


def log(msg: str = "") -> None:
    print(msg, flush=True)


def progress_bar(cur: int, total: int, prefix: str = "", extra: str = "", width: int = 36) -> None:
    if total <= 0:
        return
    pct = cur / total
    filled = int(width * pct)
    bar = "#" * filled + "-" * (width - filled)
    remain = max(0, total - cur)
    sys.stdout.write(
        f"\r{prefix} [{bar}] {cur}/{total} 已处理  剩余{remain}  ({pct*100:5.1f}%)"
        + (f"  {extra}" if extra else "")
    )
    sys.stdout.flush()
    if cur >= total:
        print(flush=True)


def is_main_cctv(name: str) -> bool:
    """CCTV1-17 / 5+ / 16 / 常见中文名主台（不含付费子频道）"""
    n = name.strip()
    if JUNK_NAME.search(n):
        return False
    if re.search(
        r"cctv[-_ ]?(?:0?[1-9]|1[0-7]|5\+|16)(?:\D|$)",
        n,
        re.I,
    ):
        return True
    if re.search(
        r"cctv[-_ ]?(综合|财经|综艺|中文国际|体育(?:赛事)?|电影|国防|军事|农业|电视剧|纪录|戏曲|少儿|新闻|音乐|奥林匹克|央视台)",
        n,
        re.I,
    ):
        return True
    if re.fullmatch(r"cctv\s*[-_]?\s*\d{1,2}.*", n, re.I):
        return True
    return False


def channel_tier(name: str, group: str) -> tuple[str, int]:
    """返回 (tier, base_score)  tier: flagship/good/ok/junk"""
    n = name.strip()
    g = group or ""

    if JUNK_NAME.search(n) or JUNK_GROUP.search(g):
        return "junk", 0

    score = 40
    tier = "ok"

    if is_main_cctv(n) or (
        ("央视" in g or re.search(r"cctv", n, re.I))
        and is_main_cctv(n)
    ):
        return "flagship", 95

    if CCTV_RE.search(n) or "央视" in g or re.search(r"cctv", n, re.I):
        if re.search(r"\bcctv\b", n, re.I) and not JUNK_NAME.search(n):
            return "good", 72
        return "ok", 45

    if WEISHI_RE.search(n) or "卫视" in g:
        return "flagship", 90

    if MAJOR_LOCAL.search(n) and re.search(r"(卫视|新闻|都市|影视|综艺|公共|经济|生活|少儿|文艺)", n):
        return "good", 78

    if MAJOR_LOCAL.search(n) or "地方" in g:
        score = 68
        tier = "good"

    if SPORTS_RE.search(n) or "体育" in g:
        score = max(score, 72)
        tier = "good"

    if re.search(r"(香港|澳门|台湾|国际|CGTN|CNN|BBC|NHK)", n, re.I) or "港澳" in g or "国际" in g:
        score = max(score, 75)
        tier = "good"

    # 名称过短/乱码/纯数字
    if len(n) < 2 or re.fullmatch(r"\d+", n):
        return "junk", 0

    # 分组很杂且名字不像电视
    if g in ("其他", "未分组", "") and score < 60 and not MAJOR_LOCAL.search(n):
        score -= 15

    if score >= 70:
        tier = "good"
    elif score < 40:
        tier = "junk"
    return tier, max(0, score)


def probe_url(url: str) -> dict:
    """严格探测：TTFB + 字节 + 粗速度。返回 metrics。"""
    t0 = time.time()
    headers = {"User-Agent": UA, "Accept": "*/*"}
    try:
        # 先小范围 GET（直播源 HEAD 常不准）
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT, context=SSL_CTX) as resp:
            ttfb = time.time() - t0
            code = resp.getcode()
            ctype = (resp.headers.get("Content-Type") or "").lower()
            chunk = resp.read(65536)
            elapsed = max(time.time() - t0, 0.001)
            n = len(chunk)
            kbps = (n * 8 / 1000.0) / elapsed

            # m3u8：再试拉一个分片
            text_head = ""
            try:
                text_head = chunk[:4096].decode("utf-8", errors="ignore")
            except Exception:
                text_head = ""

            seg_ok = True
            seg_kbps = kbps
            if "#EXTM3U" in text_head:
                seg = _first_media_url(url, text_head)
                if seg:
                    ok2, kbps2, ttfb2, n2 = _fetch_bytes(seg, 262144)
                    seg_ok = ok2 and n2 >= BYTES_MIN and ttfb2 <= TTFB_MAX + 0.8
                    if ok2:
                        seg_kbps = max(kbps2, kbps)

            ok = (
                200 <= code < 400
                and ttfb <= TTFB_MAX
                and n >= min(BYTES_MIN, 512)
                and seg_ok
                and (seg_kbps >= SPEED_MIN_KBPS or "#EXTM3U" in text_head and n >= 64)
            )
            # 内容类型过离谱直接挂
            if any(x in ctype for x in ("text/html", "application/json")) and "#EXTM3U" not in text_head:
                ok = False

            return {
                "url": url,
                "ok": ok,
                "ttfb": ttfb,
                "bytes": n,
                "kbps": seg_kbps,
                "code": code,
            }
    except Exception:
        return {"url": url, "ok": False, "ttfb": 99, "bytes": 0, "kbps": 0, "code": 0}


def _first_media_url(base: str, body: str) -> str | None:
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("http://") or line.startswith("https://"):
            return line
        return urljoin(base, line)
    return None


def _fetch_bytes(url: str, limit: int) -> tuple[bool, float, float, int]:
    t0 = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT, context=SSL_CTX) as resp:
            ttfb = time.time() - t0
            data = resp.read(limit)
            elapsed = max(time.time() - t0, 0.001)
            n = len(data)
            kbps = (n * 8 / 1000.0) / elapsed
            return 200 <= resp.getcode() < 400, kbps, ttfb, n
    except Exception:
        return False, 0.0, 99.0, 0


def ffprobe_ok(url: str, timeout: int | None = None) -> bool:
    to = timeout or FFPROBE_TIMEOUT
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=codec_type",
        "-of", "default=noprint_wrappers=1:nokey=1",
        "-timeout", str(int(to * 1_000_000)),
        "-user_agent", UA,
        url,
    ]
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=to + 3, text=True)
        return r.returncode == 0 and "video" in (r.stdout or "").lower()
    except Exception:
        return False


def ffprobe_ok_loose(url: str) -> bool:
    """旗舰保底：更长超时"""
    return ffprobe_ok(url, timeout=10)


def normalize_key(name: str) -> str:
    w = name.lower().strip()
    m = re.search(r"cctv\s*[-_ ]*0*(\d+)(\+)?", w)
    if m:
        return f"cctv{m.group(1)}{m.group(2) or ''}"
    w = re.sub(r"[\s\-—_.·.,，、。/\\|()（）\[\]【】:：]+", "", w)
    w = re.sub(r"(高清|超清|标清|蓝光|流畅|频道|直播|在线|\d+p|1080p|720p|4k)$", "", w, flags=re.I)
    return w


def line_score(m: dict) -> float:
    if not m.get("ok"):
        return 0
    # TTFB 越低越好，速度越高越好
    ttfb = m["ttfb"]
    kbps = m["kbps"]
    s = 50
    s += max(0, 30 * (1 - ttfb / TTFB_MAX))
    s += min(20, kbps / 200)
    return s


def main() -> int:
    log("=" * 68)
    log("严格质量筛选  (分级 → 复测 → 限额)")
    log("=" * 68)

    data = json.loads(INPUT.read_text(encoding="utf-8"))
    channels = data.get("channels", [])
    log(f"输入: {len(channels)} 台 / {sum(len(c.get('urls',[])) for c in channels)} 线")

    # ── 1. 分级预剔除 ──
    log("\n[1/4] 频道质量分级 + 剔除垃圾台")
    kept = []
    junk_n = 0
    for ch in channels:
        tier, base = channel_tier(ch.get("name", ""), ch.get("group", ""))
        if tier == "junk" or base < 30:
            junk_n += 1
            continue
        kept.append({**ch, "_tier": tier, "_base": base})
    log(f"  垃圾/劣质剔除: {junk_n}")
    log(f"  进入复测: {len(kept)}")
    progress_bar(len(channels), len(channels), "分级", extra=f"留{len(kept)} 丢{junk_n}")

    # ── 2. 线路严格复测 ──
    all_urls = []
    for ch in kept:
        # 旗舰台测全部线路，其它最多 5 条
        limit = 8 if ch.get("_tier") == "flagship" else 5
        for u in ch.get("urls", [])[:limit]:
            all_urls.append(u)
    # 去重保序
    seen = set()
    uniq = []
    for u in all_urls:
        if u not in seen:
            seen.add(u)
            uniq.append(u)

    log(f"\n[2/4] 严格复测线路  n={len(uniq)}  TTFB≤{TTFB_MAX}s  ≥{SPEED_MIN_KBPS}kbps")
    metrics: dict[str, dict] = {}
    done = 0
    ok_n = 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = {ex.submit(probe_url, u): u for u in uniq}
        for fut in as_completed(futs):
            u = futs[fut]
            done += 1
            try:
                m = fut.result()
            except Exception:
                m = {"url": u, "ok": False, "ttfb": 99, "bytes": 0, "kbps": 0, "code": 0}
            metrics[u] = m
            if m.get("ok"):
                ok_n += 1
            if done % 3 == 0 or done == len(uniq):
                rate = done / max(time.time() - t0, 0.01)
                eta = (len(uniq) - done) / max(rate, 0.01)
                progress_bar(done, len(uniq), "复测", extra=f"过线{ok_n} ETA{eta:.0f}s")
    log(f"  过线: {ok_n}/{len(uniq)}")

    # ── 3. 可选 FFprobe 对过线再确认 ──
    good_urls = [u for u, m in metrics.items() if m.get("ok")]
    if USE_FFPROBE and good_urls:
        log(f"\n[3/4] FFprobe 二次确认  n={len(good_urls)}")
        playable = set()
        done = 0
        t0 = time.time()
        with ThreadPoolExecutor(max_workers=FFPROBE_WORKERS) as ex:
            futs = {ex.submit(ffprobe_ok, u): u for u in good_urls}
            for fut in as_completed(futs):
                u = futs[fut]
                done += 1
                try:
                    if fut.result():
                        playable.add(u)
                except Exception:
                    pass
                if done % 2 == 0 or done == len(good_urls):
                    rate = done / max(time.time() - t0, 0.01)
                    eta = (len(good_urls) - done) / max(rate, 0.01)
                    progress_bar(done, len(good_urls), "FFprobe",
                                 extra=f"可播{len(playable)} ETA{eta:.0f}s")
        # 若 ffprobe 过严（<40%），不完全依赖它，只作加分
        ratio = len(playable) / max(len(good_urls), 1)
        log(f"  FFprobe 可播率: {ratio*100:.1f}% ({len(playable)}/{len(good_urls)})")
        for u, m in metrics.items():
            if not m.get("ok"):
                continue
            if u in playable:
                m["ff"] = True
                m["line_score"] = line_score(m) + 15
            else:
                m["ff"] = False
                # 可播率正常时，未过 ff 的降权；过严时保留
                if ratio >= 0.35:
                    m["line_score"] = line_score(m) * 0.55
                    if m["line_score"] < 35:
                        m["ok"] = False
                else:
                    m["line_score"] = line_score(m)
    else:
        log("\n[3/4] 跳过 FFprobe")
        for u, m in metrics.items():
            m["line_score"] = line_score(m) if m.get("ok") else 0

    # ── 4. 频道打分 + 限额 ──
    log(f"\n[4/4] 频道打分排序，目标 ≤{TARGET_CHANNELS} 台")
    ranked = []
    for ch in kept:
        lines = []
        for u in ch.get("urls", [])[:5]:
            m = metrics.get(u)
            if m and m.get("ok") and m.get("line_score", 0) > 0:
                lines.append((m["line_score"], m.get("ttfb", 99), u))
        lines.sort(key=lambda x: (-x[0], x[1]))
        urls = [u for _, _, u in lines[:MAX_URLS_PER_CH]]
        if not urls:
            continue

        base = ch["_base"]
        tier = ch["_tier"]
        best_line = lines[0][0]
        multi = 12 if len(urls) >= 2 else 0
        multi += 6 if len(urls) >= 3 else 0
        score = base * 0.55 + best_line * 0.35 + multi
        if tier == "flagship":
            score += 8
        if score < MIN_SCORE_KEEP:
            continue
        if score < REQUIRE_MULTI_LINE_BELOW and len(urls) < 2 and tier != "flagship":
            continue

        ranked.append({
            "name": ch["name"],
            "group": _normalize_group(ch.get("group", ""), ch["name"], tier),
            "urls": urls,
            "_score": round(score, 1),
            "_tier": tier,
        })

    ranked.sort(key=lambda x: (-x["_score"], x["name"]))

    # ── 4b. 旗舰台保底：严格复测全挂时，用更长超时 FFprobe 抢救 ──
    have_keys = {normalize_key(c["name"]) for c in ranked}
    flagship_missing = [
        ch for ch in kept
        if ch.get("_tier") == "flagship" and normalize_key(ch["name"]) not in have_keys
    ]
    if flagship_missing:
        log(f"\n[4b] 旗舰台保底抢救  缺失 {len(flagship_missing)} 台（央视/卫视）")
        rescue_urls = []
        owner = {}
        for ch in flagship_missing:
            for u in ch.get("urls", [])[:6]:
                rescue_urls.append(u)
                owner[u] = ch
        # 去重
        seen_r = set()
        runiq = []
        for u in rescue_urls:
            if u not in seen_r:
                seen_r.add(u)
                runiq.append(u)
        rescued_playable: dict[str, list[str]] = {}
        done = 0
        t0 = time.time()
        with ThreadPoolExecutor(max_workers=max(6, FFPROBE_WORKERS // 2)) as ex:
            # 更长超时的 ffprobe
            futs = {ex.submit(ffprobe_ok_loose, u): u for u in runiq}
            for fut in as_completed(futs):
                u = futs[fut]
                done += 1
                ok = False
                try:
                    ok = fut.result()
                except Exception:
                    ok = False
                if ok:
                    ch = owner[u]
                    key = normalize_key(ch["name"])
                    rescued_playable.setdefault(key, [])
                    if u not in rescued_playable[key]:
                        rescued_playable[key].append(u)
                if done % 2 == 0 or done == len(runiq):
                    rate = done / max(time.time() - t0, 0.01)
                    eta = (len(runiq) - done) / max(rate, 0.01)
                    progress_bar(done, len(runiq), "保底", extra=f"救回线{sum(len(v) for v in rescued_playable.values())} ETA{eta:.0f}s")
        # 合并回 ranked
        by_key = {normalize_key(ch["name"]): ch for ch in flagship_missing}
        add_n = 0
        for key, urls in rescued_playable.items():
            ch = by_key.get(key)
            if not ch or not urls:
                continue
            ranked.append({
                "name": ch["name"],
                "group": _normalize_group(ch.get("group", ""), ch["name"], "flagship"),
                "urls": urls[:MAX_URLS_PER_CH],
                "_score": max(88.0, ch.get("_base", 90) * 0.9),
                "_tier": "flagship",
                "_rescued": True,
            })
            add_n += 1
        ranked.sort(key=lambda x: (-x["_score"], x["name"]))
        log(f"  抢救成功: {add_n} 台旗舰")

    # 分组配额，避免某一省占满；旗舰台优先不挤掉
    final = []
    group_count: dict[str, int] = {}
    GROUP_CAP = {
        "央视": 28,   # 主台 CCTV1-17 + 5+ 等
        "卫视": 45,
        "地方": 50,
        "体育": 15,
        "港澳台": 18,
        "国际": 12,
        "其他": 15,
    }
    # 先放旗舰，再放其它
    ordered = [c for c in ranked if c.get("_tier") == "flagship"] + [
        c for c in ranked if c.get("_tier") != "flagship"
    ]
    for ch in ordered:
        g = ch["group"]
        cap = GROUP_CAP.get(g, 40)
        # 旗舰央视/卫视硬保底：略放宽 cap
        if ch.get("_tier") == "flagship" and g in ("央视", "卫视"):
            cap = max(cap, 28 if g == "央视" else 45)
        if group_count.get(g, 0) >= cap:
            continue
        final.append(ch)
        group_count[g] = group_count.get(g, 0) + 1
        if len(final) >= TARGET_CHANNELS:
            break

    # 剥离子段
    out_channels = [{"name": c["name"], "group": c["group"], "urls": c["urls"]} for c in final]
    total_urls = sum(len(c["urls"]) for c in out_channels)

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    payload = {
        "metadata": {
            "total_channels": len(out_channels),
            "valid_channels": len(out_channels),
            "total_urls_tested": len(uniq),
            "total_valid_urls": total_urls,
            "validated_at": now,
            "max_urls_per_channel": MAX_URLS_PER_CH,
            "filter": "strict_quality",
            "thresholds": {
                "ttfb_max": TTFB_MAX,
                "speed_min_kbps": SPEED_MIN_KBPS,
                "min_score": MIN_SCORE_KEEP,
                "target_channels": TARGET_CHANNELS,
            },
            "sources": data.get("metadata", {}).get("sources", []),
            "prev_channels": len(channels),
            "junk_removed": junk_n,
            "tier_counts": _count_tiers(final),
        },
        "channels": out_channels,
    }

    text = json.dumps(payload, ensure_ascii=False, indent=2)
    m3u = ["#EXTM3U"]
    for c in out_channels:
        for u in c["urls"]:
            m3u.append(f'#EXTINF:-1 group-title="{c["group"]}",{c["name"]}')
            m3u.append(u)
    m3u_text = "\n".join(m3u) + "\n"

    targets_json = [
        MIRRORS / "validated-channels.json",
        MIRRORS / "optimized-channels.json",
        MIRRORS / "strict-quality-channels.json",
        IOS_RES / "validated-channels.json",
        IOS_SCRIPTS / "validated-channels.json",
    ]
    targets_m3u = [
        MIRRORS / "validated-channels.m3u",
        MIRRORS / "optimized-channels.m3u",
        MIRRORS / "strict-quality-channels.m3u",
    ]
    log("\n[输出]")
    for p in targets_json:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        log(f"  {p}")
    for p in targets_m3u:
        p.write_text(m3u_text, encoding="utf-8")
        log(f"  {p}")

    log("\n" + "=" * 68)
    log("完成（严格）")
    log(f"  {len(channels)} → {len(out_channels)} 台")
    log(f"  线路 → {total_urls}（每台最多 {MAX_URLS_PER_CH}）")
    log(f"  分级: {_count_tiers(final)}")
    log(f"  分组: {dict(group_count)}")
    if final:
        log(f"  分数区间: {final[-1]['_score']} ~ {final[0]['_score']}")
    log("=" * 68)
    return 0


def _normalize_group(group: str, name: str, tier: str) -> str:
    g = group or "其他"
    n = name
    if re.search(r"cctv|央视", n, re.I) or "央视" in g:
        return "央视"
    if "卫视" in n or "卫视" in g:
        return "卫视"
    if re.search(r"体育|足球|NBA|CBA", n, re.I) or "体育" in g:
        return "体育"
    if re.search(r"香港|澳门|台湾|凤凰|翡翠|明珠", n) or "港澳" in g:
        return "港澳台"
    if re.search(r"CGTN|CNN|BBC|NHK|国际", n, re.I) or "国际" in g:
        return "国际"
    if "地方" in g or re.search(
        r"(北京|上海|天津|重庆|湖南|浙江|江苏|广东|四川|山东|河南|湖北|安徽|辽宁|福建|河北)",
        n,
    ):
        return "地方"
    if tier in ("flagship", "good"):
        return g if g not in ("其他", "未分组", "") else "地方"
    return "其他"


def _count_tiers(items: list[dict]) -> dict:
    from collections import Counter
    return dict(Counter(i.get("_tier", "?") for i in items))


if __name__ == "__main__":
    raise SystemExit(main())
