#!/usr/bin/env python3
"""
本地筛选频道 → 生成 validated-channels.json
1. 读本地 iptv-mirrors + 可用在线源
2. 合并同名频道
3. 快速探测 URL（GET 前 8KB / m3u8 特征）
4. 只保留至少 1 条可用线的频道
5. 写入: iptv-mirrors / scripts / Resources
"""

from __future__ import annotations

import asyncio
import json
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple
from urllib.parse import urljoin

try:
    import aiohttp
except ImportError:
    print("需要: pip install aiohttp")
    sys.exit(1)

ROOT = Path(__file__).resolve().parents[2]
MIRROR_DIR = ROOT / "iptv-mirrors"
OUT_MIRROR = MIRROR_DIR / "validated-channels.json"
OUT_SCRIPTS = Path(__file__).resolve().parent / "validated-channels.json"
OUT_BUNDLE = ROOT / "TVPlayer-iOS" / "TVPlayer_iOS" / "Resources" / "validated-channels.json"

# 本地镜像优先（无需代理）
LOCAL_M3U = [
    ("burningc4-local", MIRROR_DIR / "burningc4-chinese-iptv.m3u"),
    ("zbefine-local", MIRROR_DIR / "zbefine-iptv.m3u"),
    ("suxuang-local", MIRROR_DIR / "suxuang-myiptv.m3u"),
]

# 实测可用的在线源
REMOTE_SOURCES = [
    ("BurningC4 CDN", "https://iptv.burningc4.com/TV-IPV4.m3u"),
    ("hujingguang", "https://ghfast.top/raw.githubusercontent.com/hujingguang/ChinaIPTV/main/grouped.m3u8"),
    ("best-fan 全量", "https://gh-proxy.com/https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8"),
    ("iptv-org 中国", "https://ghfast.top/raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u"),
    ("iptv-org Pages", "https://iptv-org.github.io/iptv/countries/cn.m3u"),
]

TIMEOUT = 4
CONCURRENT = 40
MAX_URLS_PER_CHANNEL = 3
# 优先保留的分组关键词（先筛「好台」）
PRIORITY_GROUPS = ("央视", "CCTV", "卫视", "地方", "体育", "港澳", "国际", "教育")
# 每台最多试多少条线（加速）
MAX_TRY_URLS = 6


def normalize_name(name: str) -> str:
    n = re.sub(r"\s+", " ", name.strip())
    n = re.sub(r"(高清|超清|蓝光|流畅|直播|在线|测试|备用\d*|线路\d+|源\d+)$", "", n, flags=re.I)
    return n.strip() or name.strip()


def parse_m3u(content: str) -> List[Dict]:
    channels: Dict[str, Dict] = {}
    pending_name = None
    pending_group = "其他"
    for raw in content.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#EXTINF:"):
            gm = re.search(r'group-title="([^"]*)"', line)
            pending_group = gm.group(1) if gm else "其他"
            if "," in line:
                pending_name = line.split(",", 1)[-1].strip()
            else:
                pending_name = "未知"
            continue
        if line.startswith("#"):
            continue
        if pending_name and (line.startswith("http://") or line.startswith("https://")):
            name = normalize_name(pending_name)
            key = name.lower()
            if key not in channels:
                channels[key] = {"name": name, "group": pending_group, "urls": []}
            if line not in channels[key]["urls"]:
                channels[key]["urls"].append(line)
            # 央视统一分组
            if re.search(r"cctv", name, re.I) or "央视" in name:
                channels[key]["group"] = "央视"
            pending_name = None
            pending_group = "其他"
    return list(channels.values())


def load_local() -> List[Tuple[str, List[Dict]]]:
    out = []
    for name, path in LOCAL_M3U:
        if not path.exists():
            print(f"[跳过] 本地不存在 {path}")
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        chs = parse_m3u(text)
        print(f"[本地] {name}: {len(chs)} 频道")
        out.append((name, chs))
    return out


async def download_remote(session: aiohttp.ClientSession, name: str, url: str) -> Tuple[str, List[Dict]]:
    print(f"[下载] {name}")
    try:
        async with session.get(url, timeout=aiohttp.ClientTimeout(total=40)) as resp:
            if resp.status != 200:
                print(f"[失败] {name}: HTTP {resp.status}")
                return name, []
            text = await resp.text(errors="ignore")
            chs = parse_m3u(text)
            print(f"[成功] {name}: {len(chs)} 频道")
            return name, chs
    except Exception as e:
        print(f"[失败] {name}: {e}")
        return name, []


async def probe_url(session: aiohttp.ClientSession, url: str) -> bool:
    headers = {
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
        "Accept": "*/*",
    }
    try:
        async with session.get(
            url,
            timeout=aiohttp.ClientTimeout(total=TIMEOUT),
            allow_redirects=True,
            headers=headers,
        ) as resp:
            if resp.status >= 400:
                return False
            chunk = await resp.content.read(8192)
            if not chunk:
                return False
            # HLS / 文本 playlist
            try:
                text = chunk.decode("utf-8", errors="ignore")
            except Exception:
                text = ""
            if "#EXTM3U" in text or "#EXTINF" in text or "#EXT-X" in text:
                return True
            # 裸 TS
            if chunk[0:1] == b"\x47":
                return True
            # 部分源返回 JSON/HTML 失败页
            if "<html" in text.lower() or "not found" in text.lower():
                return False
            # 有足够字节且非明显错误页 → 弱通过
            return len(chunk) >= 200
    except Exception:
        return False


def priority_score(ch: Dict) -> int:
    g = ch.get("group", "")
    n = ch.get("name", "")
    score = 0
    for i, kw in enumerate(PRIORITY_GROUPS):
        if kw in g or kw in n:
            score += 100 - i
    if re.search(r"CCTV-?\d+", n, re.I):
        score += 50
    if "卫视" in n:
        score += 30
    return score


async def validate_all(channels: List[Dict]) -> List[Dict]:
    # 优先验证高价值频道
    channels = sorted(channels, key=priority_score, reverse=True)
    sem = asyncio.Semaphore(CONCURRENT)
    validated: List[Dict] = []
    tested = 0
    ok_urls = 0
    lock = asyncio.Lock()

    async with aiohttp.ClientSession(
        connector=aiohttp.TCPConnector(limit=CONCURRENT, ssl=False)
    ) as session:

        async def one(ch: Dict):
            nonlocal tested, ok_urls
            good = []
            for url in ch["urls"][:MAX_TRY_URLS]:
                async with sem:
                    ok = await probe_url(session, url)
                async with lock:
                    tested += 1
                    if tested % 80 == 0:
                        print(f"[探测] {tested} URLs, 已通过频道 {len(validated)}")
                if ok:
                    good.append(url)
                    async with lock:
                        ok_urls += 1
                    if len(good) >= MAX_URLS_PER_CHANNEL:
                        break
            if good:
                return {"name": ch["name"], "group": ch["group"], "urls": good}
            return None

        results = await asyncio.gather(*[one(c) for c in channels])
        for r in results:
            if r:
                validated.append(r)

    print(f"[统计] 测试 URL {tested}, 可用 URL {ok_urls}, 可用频道 {len(validated)}")
    return validated


def merge(sources: List[Tuple[str, List[Dict]]]) -> List[Dict]:
    merged: Dict[str, Dict] = {}
    for _, chs in sources:
        for ch in chs:
            key = ch["name"].lower()
            if key not in merged:
                merged[key] = {"name": ch["name"], "group": ch["group"], "urls": []}
            for u in ch["urls"]:
                if u not in merged[key]["urls"]:
                    merged[key]["urls"].append(u)
            # 保留更好的 group
            if priority_score(ch) > priority_score(merged[key]):
                merged[key]["group"] = ch["group"]
    return list(merged.values())


def write_outputs(channels: List[Dict], source_names: List[str], total_before: int):
    # 排序：央视/卫视优先
    channels = sorted(channels, key=priority_score, reverse=True)
    result = {
        "channels": channels,
        "metadata": {
            "total_channels": total_before,
            "valid_channels": len(channels),
            "total_valid_urls": sum(len(c["urls"]) for c in channels),
            "validated_at": datetime.now().isoformat(timespec="seconds"),
            "max_urls_per_channel": MAX_URLS_PER_CHANNEL,
            "sources": source_names,
            "validation_method": "local filter + HTTP probe 8KB",
            "mirror_url": "https://wfygefjgd.github.io/live-player/iptv-mirrors/validated-channels.json",
        },
    }
    for path in (OUT_MIRROR, OUT_SCRIPTS, OUT_BUNDLE):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"[写入] {path} ({len(channels)} 频道)")


async def main():
    print("=" * 60)
    print("TVPlayer 本地筛选 → validated-channels.json")
    print("=" * 60)

    sources: List[Tuple[str, List[Dict]]] = []
    sources.extend(load_local())

    async with aiohttp.ClientSession() as session:
        remote = await asyncio.gather(
            *[download_remote(session, n, u) for n, u in REMOTE_SOURCES]
        )
    for name, chs in remote:
        if chs:
            sources.append((name, chs))

    names = [n for n, _ in sources]
    merged = merge(sources)
    print(f"\n[合并] {len(merged)} 个频道，开始探测...\n")
    validated = await validate_all(merged)
    write_outputs(validated, names, len(merged))
    print("\n完成。请 git push 后由 GitHub Pages 提供镜像。")


if __name__ == "__main__":
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    asyncio.run(main())
