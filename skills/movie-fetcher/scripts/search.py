"""BT 资源多源搜索 + 诊断。

源列表：
1. jiaofu — 教父 BT 站（opencli adapter，需 Chrome 登录态）
2. YTS — 英文电影专用 JSON API
3. apibay — PirateBay 社区 JSON API（不识别 CJK）
4. btdig — DHT 搜索引擎 HTML 解析（万能兜底）

搜索全部源后合并去重；同时返回 per-source 诊断信息，
用于在无结果时输出具体原因而非模糊的「无结果」。
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import time
import urllib.parse
from dataclasses import dataclass, asdict, field
from enum import Enum, auto
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


# ─── diagnostics ────────────────────────────────────────────────────────────


class SourceStatus(Enum):
    OK = auto()            # 正常返回，有或无结果
    TIMEOUT = auto()       # 请求超时
    BLOCKED = auto()       # 安全封控 / 反爬页面
    NOT_AVAILABLE = auto() # 源不可用（如 opencli 未安装）
    NETWORK_ERROR = auto() # 网络错误（DNS/连接失败/HTTP 非 200）
    NO_RESULTS = auto()    # 正常返回但无匹配结果
    NO_CJK_SUPPORT = auto() # 源不支持中文搜索（如 apibay CJK 噪声过滤）


@dataclass
class SearchDiagnostic:
    source: str
    status: SourceStatus
    detail: str = ""
    result_count: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "status": self.status.name,
            "detail": self.detail,
            "result_count": self.result_count,
        }


# ─── security-page detection ────────────────────────────────────────────────

# btdig 常见封控页面特征
_BTDIG_BLOCK_PATTERNS = [
    # Cloudflare challenge
    "cf-browser-verify",
    "challenge-platform",
    "Checking your browser",
    "Just a moment",
    # Generic captcha / DDoS protection
    "captcha",
    "verify you are human",
    "security check",
    "DDoS protection",
    "Please enable JavaScript",
    "Access Denied",
    "429 Too Many Requests",
    "<title>Attention Required",
    # Empty results can also indicate silent block (no .one_result after parse)
]

# apibay 限流 / 封控
_APIBAY_BLOCK_PATTERNS = [
    "rate limit",
    "too many requests",
    "blocked",
]


def _detect_blocked(html_or_body: str, patterns: list[str]) -> str | None:
    """检测封控特征，返回匹配的模式描述；无封控返回 None。"""
    low = html_or_body.lower()
    for pat in patterns:
        if pat.lower() in low:
            return pat
    return None


def _is_silent_block_btdig(soup) -> bool:
    """btdig 可能返回看起来正常的页面但没有任何搜索结果（被静默封控）。
    
    特征：页面没有 .one_result 元素，且页面文本极少（<500 字符），
    或者 title 显示为验证页。
    """
    from bs4 import BeautifulSoup
    text = soup.get_text(strip=True)
    if len(text) < 500:
        return True
    title_tag = soup.find("title")
    if title_tag:
        title_text = title_tag.get_text(strip=True).lower()
        for kw in ("attention required", "blocked", "captcha", "just a moment"):
            if kw in title_text:
                return True
    return False


# ─── results ────────────────────────────────────────────────────────────────


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


def search_jiaofu(query: str, timeout: int = 60) -> tuple[list[Result], SearchDiagnostic]:
    """通过 opencli jiaofu adapter 调教父站。中文影视首选源。"""
    diag = SearchDiagnostic(source="jiaofu", status=SourceStatus.OK, detail="")
    if not shutil.which("opencli"):
        diag.status = SourceStatus.NOT_AVAILABLE
        diag.detail = "opencli 未安装（需要 Chrome 登录态才能调教父站）"
        return [], diag
    real_timeout = max(int(timeout), 60)
    try:
        proc = subprocess.run(
            ["opencli", "jiaofu", "search", query, "--limit", "50", "-f", "json"],
            capture_output=True, text=True, timeout=real_timeout,
        )
    except subprocess.TimeoutExpired:
        diag.status = SourceStatus.TIMEOUT
        diag.detail = f"opencli 搜索超时（>{real_timeout}s）"
        return [], diag
    if proc.returncode != 0:
        diag.status = SourceStatus.NETWORK_ERROR
        detail = proc.stderr.strip()[:200] if proc.stderr else ""
        diag.detail = f"opencli 非零退出码 {proc.returncode}" + (f": {detail}" if detail else "")
        return [], diag
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        diag.status = SourceStatus.NETWORK_ERROR
        diag.detail = "opencli 返回非 JSON（可能登录态失效）"
        return [], diag
    if not isinstance(data, list):
        diag.status = SourceStatus.NETWORK_ERROR
        diag.detail = "opencli 返回格式异常（非列表）"
        return [], diag
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
    diag.result_count = len(results)
    if not results:
        diag.status = SourceStatus.NO_RESULTS
        diag.detail = f"jiaofu 无匹配「{query}」的结果"
    return results, diag


# ─── source 1: YTS ───────────────────────────────────────────────────────────


def search_yts(query: str, timeout: int = DEFAULT_TIMEOUT) -> tuple[list[Result], SearchDiagnostic]:
    diag = SearchDiagnostic(source="yts", status=SourceStatus.OK, detail="")
    url = "https://yts.mx/api/v2/list_movies.json"
    params = {"query_term": query, "limit": 10}
    try:
        r = requests.get(url, params=params, headers={"User-Agent": UA}, timeout=timeout)
        r.raise_for_status()
        data = r.json()
    except requests.Timeout:
        diag.status = SourceStatus.TIMEOUT
        diag.detail = f"YTS API 超时（>{timeout}s）"
        return [], diag
    except requests.HTTPError as e:
        diag.status = SourceStatus.NETWORK_ERROR
        diag.detail = f"YTS HTTP {e.response.status_code if e.response else '?'}"
        return [], diag
    except Exception as e:
        diag.status = SourceStatus.NETWORK_ERROR
        diag.detail = f"YTS 请求失败: {e}"
        return [], diag
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
    diag.result_count = len(results)
    if not results:
        diag.status = SourceStatus.NO_RESULTS
        diag.detail = f"YTS 无匹配（仅英文片源，中文搜索默认无结果）"
    return results, diag


# ─── source 2: apibay (PirateBay 社区 API) ──────────────────────────────────


def _has_cjk(s: str) -> bool:
    return any("\u4e00" <= ch <= "\u9fff" for ch in s)


def search_apibay(query: str, timeout: int = DEFAULT_TIMEOUT) -> tuple[list[Result], SearchDiagnostic]:
    diag = SearchDiagnostic(source="apibay", status=SourceStatus.OK, detail="")
    url = "https://apibay.org/q.php"
    params = {"q": query, "cat": "200"}
    try:
        r = requests.get(url, params=params, headers={"User-Agent": UA}, timeout=timeout)
        r.raise_for_status()
    except requests.Timeout:
        diag.status = SourceStatus.TIMEOUT
        diag.detail = f"apibay 超时（>{timeout}s）"
        return [], diag
    except requests.HTTPError as e:
        status_code = e.response.status_code if e.response else "?"
        diag.status = SourceStatus.NETWORK_ERROR
        diag.detail = f"apibay HTTP {status_code}"
        return [], diag
    except Exception as e:
        diag.status = SourceStatus.NETWORK_ERROR
        diag.detail = f"apibay 请求失败: {e}"
        return [], diag

    # 检查响应文本是否包含限流/封控特征
    raw = r.text.lower()
    if block_reason := _detect_blocked(raw, _APIBAY_BLOCK_PATTERNS):
        diag.status = SourceStatus.BLOCKED
        diag.detail = f"apibay 触发限制: 「{block_reason}」"
        return [], diag

    try:
        data = r.json()
    except Exception:
        diag.status = SourceStatus.NETWORK_ERROR
        diag.detail = "apibay 返回非 JSON"
        return [], diag
    if not isinstance(data, list) or not data:
        diag.status = SourceStatus.NO_RESULTS
        diag.detail = "apibay 返回异常数据"
        return [], diag
    if len(data) == 1 and data[0].get("id") == "0":
        diag.status = SourceStatus.NO_RESULTS
        diag.detail = f"apibay 无匹配"
        return [], diag

    # apibay 不识别 CJK；query 含中文时它返回 trending 当默认列表
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
    diag.result_count = len(results)
    if not results:
        diag.status = SourceStatus.NO_CJK_SUPPORT
        if query_cjk:
            diag.detail = f"apibay 不支持中文搜索「{query}」，返回的英文列表已过滤"
        else:
            diag.status = SourceStatus.NO_RESULTS
            diag.detail = "apibay 无匹配"
    return results, diag


# ─── source 3: btdig HTML ───────────────────────────────────────────────────


def search_btdig(query: str, timeout: int = DEFAULT_TIMEOUT) -> tuple[list[Result], SearchDiagnostic]:
    from bs4 import BeautifulSoup

    diag = SearchDiagnostic(source="btdig", status=SourceStatus.OK, detail="")
    if " " in query and not query.startswith('"'):
        exact_query = f'"{query}"'
    else:
        exact_query = query
    url = "https://btdig.com/search"
    try:
        r = requests.get(url, params={"q": exact_query}, headers={"User-Agent": UA}, timeout=timeout)
        r.raise_for_status()
    except requests.Timeout:
        diag.status = SourceStatus.TIMEOUT
        diag.detail = f"btdig 超时（>{timeout}s），可能被墙或网络不通"
        return [], diag
    except requests.HTTPError as e:
        status_code = e.response.status_code if e.response else "?"
        diag.status = SourceStatus.NETWORK_ERROR
        if status_code == 429:
            diag.status = SourceStatus.BLOCKED
            diag.detail = "btdig 返回 429（请求过频，触发了频率限制）"
        else:
            diag.detail = f"btdig HTTP {status_code}"
        return [], diag
    except Exception as e:
        diag.status = SourceStatus.NETWORK_ERROR
        diag.detail = f"btdig 请求失败: {type(e).__name__}"
        return [], diag

    html = r.text

    # 检测安全封控页面
    if block_reason := _detect_blocked(html, _BTDIG_BLOCK_PATTERNS):
        diag.status = SourceStatus.BLOCKED
        diag.detail = f"btdig 触发安全验证: 「{block_reason}」"
        return [], diag

    soup = BeautifulSoup(html, "html.parser")
    if _is_silent_block_btdig(soup):
        diag.status = SourceStatus.BLOCKED
        diag.detail = "btdig 疑似静默封控（页面无搜索结果且内容极少）"
        return [], diag

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
        results.append(Result(title=title, seeders=-1, size=size, magnet=magnet, source="btdig"))
        if len(results) >= 20:
            break
    diag.result_count = len(results)
    if not results:
        diag.status = SourceStatus.NO_RESULTS
        diag.detail = f"btdig 无匹配「{query}」的结果"
    return results, diag


# ─── orchestration ──────────────────────────────────────────────────────────


SOURCES: list[tuple[str, Callable[[str, int], tuple[list[Result], SearchDiagnostic]]]] = [
    ("jiaofu", search_jiaofu),
    ("yts", search_yts),
    ("apibay", search_apibay),
    ("btdig", search_btdig),
]

# 源间延迟（秒），避免连续请求触发安全封控
INTER_SOURCE_DELAY = 1.0


def search_all(
    query: str, timeout: int = DEFAULT_TIMEOUT, limit: int = 10,
) -> tuple[list[Result], list[SearchDiagnostic]]:
    """合并所有源的结果（去重）并返回 per-source 诊断。
    
    Returns:
        (results, diagnostics) — diagnostics 始终包含每个源的执行状态。
    """
    all_results: list[Result] = []
    seen_titles: set[str] = set()
    diagnostics: list[SearchDiagnostic] = []

    for idx, (name, fn) in enumerate(SOURCES):
        # 第一个源无需延迟，后续源之间加延迟避免被封
        if idx > 0:
            time.sleep(INTER_SOURCE_DELAY)

        try:
            res, diag = fn(query, timeout)
        except Exception as e:  # noqa: BLE001
            diag = SearchDiagnostic(
                source=name,
                status=SourceStatus.NETWORK_ERROR,
                detail=f"未预期的异常: {type(e).__name__}: {e}",
            )
            res = []

        diagnostics.append(diag)
        for r in res:
            title_key = r.title.lower().strip()
            if title_key not in seen_titles:
                seen_titles.add(title_key)
                all_results.append(r)

        if len(all_results) >= limit * 3:
            break

    return all_results[:limit], diagnostics


# ─── 格式化诊断输出 ────────────────────────────────────────────────────────

STATUS_LABELS: dict[SourceStatus, str] = {
    SourceStatus.OK:             "✓",
    SourceStatus.TIMEOUT:        "⏱ 超时",
    SourceStatus.BLOCKED:        "🚫 被封",
    SourceStatus.NOT_AVAILABLE:  "✗ 不可用",
    SourceStatus.NETWORK_ERROR:  "✗ 网络错误",
    SourceStatus.NO_RESULTS:     "— 无结果",
    SourceStatus.NO_CJK_SUPPORT: "— 不支持中文",
}


def format_diagnostics(diagnostics: list[SearchDiagnostic]) -> str:
    """将诊断列表格式化为人类可读的多行摘要。"""
    lines = ["搜索诊断："]
    for d in diagnostics:
        label = STATUS_LABELS.get(d.status, d.status.name)
        parts = [f"  {label}  {d.source}"]
        if d.result_count:
            parts.append(f"({d.result_count}条)")
        if d.detail:
            parts.append(f"— {d.detail}")
        lines.append(" ".join(parts))
    return "\n".join(lines)


def diagnostics_summary(diagnostics: list[SearchDiagnostic]) -> str:
    """生成一句话摘要（用于嵌入错误信息）。"""
    blocked = [d for d in diagnostics if d.status == SourceStatus.BLOCKED]
    errors = [d for d in diagnostics if d.status in (SourceStatus.TIMEOUT, SourceStatus.NETWORK_ERROR)]
    no_results = [d for d in diagnostics if d.status == SourceStatus.NO_RESULTS]
    no_cjk = [d for d in diagnostics if d.status == SourceStatus.NO_CJK_SUPPORT]
    unavailable = [d for d in diagnostics if d.status == SourceStatus.NOT_AVAILABLE]

    parts = []
    if blocked:
        parts.append(f"{len(blocked)}个源被安全封控（{', '.join(d.source for d in blocked)}）")
    if errors:
        parts.append(f"{len(errors)}个源连接失败（{', '.join(d.source for d in errors)}）")
    if no_cjk:
        parts.append(f"{len(no_cjk)}个源不支持中文搜索（{', '.join(d.source for d in no_cjk)}）")
    if unavailable:
        parts.append(f"{len(unavailable)}个源不可用（{', '.join(d.source for d in unavailable)}）")
    if no_results and not parts:
        parts.append(f"共{len(no_results)}个源均无匹配结果")
    return "；".join(parts) if parts else "所有源均无匹配"


# ─── 自动选最佳 ─────────────────────────────────────────────────────────────


def _quality_rank(title: str, prefer: list[str]) -> int:
    """匹配偏好顺序，靠前的得分越高。"""
    low = title.lower()
    for i, q in enumerate(prefer):
        if q.lower() in low:
            return len(prefer) - i
    return 0


def _title_relevance(title: str, query: str) -> float:
    """计算标题与搜索词的关键词匹配率 (0-1)。过滤 btdig 等源的噪音。"""
    title_low = title.lower()
    query_words = re.findall(r'\w+', query.lower())
    if not query_words:
        return 1.0
    matched = sum(1 for w in query_words if w in title_low)
    return matched / len(query_words)


def pick_best(results: list[Result], prefer_quality: list[str], query: str = "") -> Result | None:
    if not results:
        return None
    if query:
        filtered = [r for r in results if _title_relevance(r.title, query) >= 0.3]
        if filtered:
            results = filtered
    return max(
        results,
        key=lambda r: (_quality_rank(r.title, prefer_quality), r.seeders),
    )
