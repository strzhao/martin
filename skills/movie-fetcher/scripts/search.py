"""BT 资源三源搜索 fallback。

电影场景下：
1. YTS 官方 JSON API（电影专用，最稳，但只英文片）
2. apibay.org（PirateBay 社区 API，JSON）
3. btdig.com（HTML 解析，万能兜底）

任一源出结果即返回；三源全空时返回空列表。
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import urllib.parse
from dataclasses import dataclass, asdict
from typing import Any, Callable

import requests

UA = "movie-fetcher/0.1 (+https://example.local)"

DEFAULT_TIMEOUT = 5

# 公共 BT trackers（apibay 等只返回 info hash，需要补 tracker 拼成 magnet）
TRACKERS = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
]


@dataclass
class Result:
    title: str
    seeders: int
    size: str
    magnet: str
    source: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _info_hash_to_magnet(info_hash: str, name: str) -> str:
    encoded_name = urllib.parse.quote(name)
    trackers = "&".join(f"tr={urllib.parse.quote(t)}" for t in TRACKERS)
    return f"magnet:?xt=urn:btih:{info_hash}&dn={encoded_name}&{trackers}"


def _human_size(num_bytes: int | str) -> str:
    try:
        n = float(num_bytes)
    except (TypeError, ValueError):
        return str(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


# ─── source 0: 教父 BT 站（opencli adapter，需要 Chrome 登录态） ────────────


def search_jiaofu(query: str, timeout: int = 60) -> list[Result]:
    """通过 opencli jiaofu adapter 调教父站。中文电影首选源。"""
    if not shutil.which("opencli"):
        return []
    # opencli 需要启动浏览器并加载两次页面（搜索 + 详情），
    # 公网源 5-8s 的超时不够用；这里设最低 60s。
    real_timeout = max(int(timeout), 60)
    try:
        proc = subprocess.run(
            ["opencli", "jiaofu", "search", query, "--limit", "50", "-f", "json"],
            capture_output=True, text=True, timeout=real_timeout,
        )
    except subprocess.TimeoutExpired:
        return []
    if proc.returncode != 0:
        return []
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    if not isinstance(data, list):
        return []
    results: list[Result] = []
    for it in data:
        magnet = it.get("magnet")
        if not magnet:
            continue
        results.append(Result(
            title=it.get("title", ""),
            seeders=int(it.get("seeds") or 0),
            size=str(it.get("size") or ""),
            magnet=magnet,
            source="jiaofu",
        ))
    return results


# ─── source 1: YTS ───────────────────────────────────────────────────────────


def search_yts(query: str, timeout: int = DEFAULT_TIMEOUT) -> list[Result]:
    url = "https://yts.mx/api/v2/list_movies.json"
    params = {"query_term": query, "limit": 10}
    try:
        r = requests.get(url, params=params, headers={"User-Agent": UA}, timeout=timeout)
        r.raise_for_status()
        data = r.json()
    except Exception:  # noqa: BLE001
        return []
    movies = (data.get("data") or {}).get("movies") or []
    results: list[Result] = []
    for m in movies:
        for t in m.get("torrents") or []:
            title = f"{m.get('title')} ({m.get('year')}) [{t.get('quality')} {t.get('type')}]"
            results.append(Result(
                title=title,
                seeders=int(t.get("seeds") or 0),
                size=t.get("size") or _human_size(t.get("size_bytes") or 0),
                magnet=_info_hash_to_magnet(t.get("hash"), title),
                source="yts",
            ))
    return results


# ─── source 2: apibay (PirateBay 社区 API) ──────────────────────────────────


def _has_cjk(s: str) -> bool:
    return any("一" <= ch <= "鿿" for ch in s)


def search_apibay(query: str, timeout: int = DEFAULT_TIMEOUT) -> list[Result]:
    url = "https://apibay.org/q.php"
    params = {"q": query, "cat": "200"}  # cat 200 = Video
    try:
        r = requests.get(url, params=params, headers={"User-Agent": UA}, timeout=timeout)
        r.raise_for_status()
        data = r.json()
    except Exception:  # noqa: BLE001
        return []
    if not isinstance(data, list) or not data:
        return []
    # apibay 在无结果时返回 [{id:'0', name:'No results...', ...}]
    if len(data) == 1 and data[0].get("id") == "0":
        return []
    # apibay 不识别 CJK；query 含中文时它返回 trending 当默认列表。
    # 兜底：query 含 CJK 且 title 全是 ASCII，认为是噪声直接丢。
    query_cjk = _has_cjk(query)
    results: list[Result] = []
    for it in data:
        info_hash = it.get("info_hash")
        if not info_hash:
            continue
        name = it.get("name", "")
        if query_cjk and not _has_cjk(name):
            continue
        results.append(Result(
            title=name,
            seeders=int(it.get("seeders") or 0),
            size=_human_size(it.get("size") or 0),
            magnet=_info_hash_to_magnet(info_hash, name),
            source="apibay",
        ))
    return results


# ─── source 3: btdig HTML ───────────────────────────────────────────────────


def search_btdig(query: str, timeout: int = DEFAULT_TIMEOUT) -> list[Result]:
    from bs4 import BeautifulSoup

    url = "https://btdig.com/search"
    try:
        r = requests.get(url, params={"q": query}, headers={"User-Agent": UA}, timeout=timeout)
        r.raise_for_status()
    except Exception:  # noqa: BLE001
        return []
    soup = BeautifulSoup(r.text, "html.parser")
    results: list[Result] = []
    for item in soup.select(".one_result"):
        a = item.select_one(".torrent_name a") or item.select_one("a[href^='magnet:']")
        if not a:
            continue
        title = a.get_text(strip=True)
        magnet_a = item.select_one("a[href^='magnet:']")
        magnet = magnet_a["href"] if magnet_a and magnet_a.has_attr("href") else ""
        if not magnet:
            continue
        size_el = item.select_one(".torrent_size")
        size = size_el.get_text(strip=True) if size_el else "?"
        # btdig 不直接给 seeders，给个 -1 让排序时排后面
        results.append(Result(title=title, seeders=-1, size=size, magnet=magnet, source="btdig"))
        if len(results) >= 20:
            break
    return results


# ─── orchestration ──────────────────────────────────────────────────────────


SOURCES: list[tuple[str, Callable[[str, int], list[Result]]]] = [
    ("jiaofu", search_jiaofu),  # 中文 BT 站，登录态；最稳，首选
    ("yts", search_yts),
    ("apibay", search_apibay),
    ("btdig", search_btdig),
]


def search_all(query: str, timeout: int = DEFAULT_TIMEOUT, limit: int = 10) -> list[Result]:
    """按顺序尝试每个源；第一个非空源即返回。"""
    for name, fn in SOURCES:
        try:
            res = fn(query, timeout)
        except Exception:  # noqa: BLE001
            res = []
        if res:
            return res[:limit]
    return []


# ─── 自动选最佳 ─────────────────────────────────────────────────────────────


def _quality_rank(title: str, prefer: list[str]) -> int:
    """匹配偏好顺序，靠前的得分越高。"""
    low = title.lower()
    for i, q in enumerate(prefer):
        if q.lower() in low:
            return len(prefer) - i
    return 0


def pick_best(results: list[Result], prefer_quality: list[str]) -> Result | None:
    if not results:
        return None
    return max(
        results,
        key=lambda r: (_quality_rank(r.title, prefer_quality), r.seeders),
    )
