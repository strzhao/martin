"""每周新片发现：教父站列表（按首播排序）→ 豆瓣分过滤 → 详情补全 →
剧集只留全集完成 → sqlite 去重 → markdown 周报。

设计要点：
- 评分源 = 教父站列表卡片自带的豆瓣分（绕过豆瓣反爬）
- 「上周新片」= sort=date 拉最新若干页 + 豆瓣≥阈值；剧集额外要求全集完成
- 去重用 sqlite，已推过的 href 跳过，避免周报重复
"""

from __future__ import annotations

import json
import re
import shutil
import sqlite3
import subprocess
import time
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any


# ─── opencli 调用 ────────────────────────────────────────────────────────────

def _run_opencli(args: list[str], timeout: int = 120) -> Any:
    """跑 `opencli jiaofu <args> -f json`，raw_decode 跳过 stdout 尾部噪声。"""
    if not shutil.which("opencli"):
        raise RuntimeError("opencli 不在 PATH；请先安装并 `opencli daemon restart`")
    proc = subprocess.run(
        ["opencli", "jiaofu", *args, "-f", "json"],
        capture_output=True, text=True, timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"opencli 返回 {proc.returncode}: {proc.stderr[:200]}")
    raw = proc.stdout.strip()
    if not raw:
        return [] if (args and args[0] == "list") else {}
    return json.JSONDecoder().raw_decode(raw.lstrip())[0]


# ─── 数据模型 ────────────────────────────────────────────────────────────────

@dataclass
class Item:
    title: str
    href: str
    kind: str               # mv / tv
    douban: float
    rating_count: str
    status: str             # 全N集 / 第N集 / 预告 / 连载
    year: str
    region: str
    genre: str
    first_air_date: str = ""
    imdb: str = ""
    director: str = ""
    cast: str = ""
    synopsis: str = ""
    updated: str = ""       # 详情页"最后更新于X天前"

    @property
    def finished(self) -> bool:
        """剧集是否全集完成（卡片状态含「全」，如「全12集」）。"""
        return "全" in self.status


def _parse_score(s: str) -> float:
    m = re.search(r"\d+(?:\.\d+)?", s or "")
    return float(m.group()) if m else 0.0


# ─── 流程 ────────────────────────────────────────────────────────────────────

def fetch_list(kind: str, sort: str, pages: int) -> list[Item]:
    """拉 sort 排序的列表，跳过豆瓣无分（--）的条目。"""
    out: list[Item] = []
    for p in range(1, pages + 1):
        try:
            rows = _run_opencli(["list", "--kind", kind, "--sort", sort,
                                 "--page", str(p), "--limit", "48"], timeout=120)
        except Exception:
            break
        if not rows:
            break
        for r in rows:
            d = _parse_score(r.get("douban", ""))
            if d <= 0:
                continue  # 预告/未开分
            out.append(Item(
                title=r.get("title", ""), href=r.get("href", ""), kind=kind,
                douban=d, rating_count=r.get("rating_count", ""),
                status=r.get("status", ""), year=r.get("year", ""),
                region=r.get("region", ""), genre=r.get("genre", ""),
            ))
        time.sleep(0.4)
    return out


def enrich(items: list[Item]) -> None:
    """对候选调 detail 补全首播日期/简介/IMDb/主演。就地修改。"""
    for it in items:
        try:
            d = _run_opencli(["detail", it.href], timeout=90)
        except Exception:
            continue
        if not isinstance(d, dict):
            continue
        it.first_air_date = d.get("first_air_date", "")
        it.imdb = str(d.get("imdb", ""))
        it.director = d.get("director", "")
        it.cast = d.get("cast", "")
        it.synopsis = d.get("synopsis", "")
        it.updated = d.get("updated", "")
        time.sleep(0.3)


# ─── 去重（sqlite） ──────────────────────────────────────────────────────────

def _init_db(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute("""CREATE TABLE IF NOT EXISTS pushed(
        href TEXT PRIMARY KEY, kind TEXT, title TEXT, douban REAL, pushed_at TEXT)""")
    conn.commit()
    return conn


def dedupe(items: list[Item], db_path: Path) -> list[Item]:
    conn = _init_db(db_path)
    pushed = {r[0] for r in conn.execute("SELECT href FROM pushed")}
    conn.close()
    return [i for i in items if i.href not in pushed]


def mark_pushed(items: list[Item], db_path: Path) -> None:
    conn = _init_db(db_path)
    today = date.today().isoformat()
    conn.executemany(
        "INSERT OR IGNORE INTO pushed(href,kind,title,douban,pushed_at) VALUES(?,?,?,?,?)",
        [(i.href, i.kind, i.title, i.douban, today) for i in items])
    conn.commit()
    conn.close()


# ─── 周报渲染 ────────────────────────────────────────────────────────────────

def render(items: list[Item], min_score: float) -> str:
    if not items:
        return f"本周暂无豆瓣 ≥ {min_score} 的新片 🌙（教父站最近开分的新片都没到线）"
    movies = sorted([i for i in items if i.kind == "mv"], key=lambda x: -x.douban)
    tvs = sorted([i for i in items if i.kind == "tv"], key=lambda x: -x.douban)
    lines = [f"🎬 本周新片速递（豆瓣 ≥ {min_score}，共 {len(items)} 部）", ""]

    def block(title: str, group: list[Item]):
        if not group:
            return
        lines.append(f"【{title}】")
        for i, it in enumerate(group, 1):
            head = f"{i}. 《{it.title}》⭐{it.douban}"
            if it.imdb:
                head += f" ｜ IMDb {it.imdb}"
            lines.append(head)
            meta = f"   {it.year}/{it.region}/{it.genre}"
            if it.first_air_date:
                meta += f" · 首播 {it.first_air_date}"
            if it.updated:
                meta += f" · 更新 {it.updated}"
            lines.append(meta)
            if it.cast:
                lines.append(f"   主演 {it.cast[:40]}")
            if it.synopsis:
                lines.append(f"   {it.synopsis[:70]}")
            lines.append(f"   ↳ 回复「下 {it.title}」推到 NAS 下载")
        lines.append("")

    block("剧集 · 全集完成", tvs)
    block("电影", movies)
    return "\n".join(lines).rstrip() + "\n"


# ─── 入口 ────────────────────────────────────────────────────────────────────

def run_weekly(kinds: list[str], min_score: float, pages: int,
               dry_run: bool, db_path: Path) -> str:
    """端到端：发现 → 过滤 → 去重 → 补全 → 渲染。返回周报文本。
    去重在 enrich 前：已推过的不再开浏览器抓详情，二次跑秒返回。"""
    all_items: list[Item] = []
    for kind in kinds:
        items = fetch_list(kind, sort="date", pages=pages)
        items = [i for i in items if i.douban >= min_score]
        if kind == "tv":
            items = [i for i in items if i.finished]  # 剧集只留全集完成
        items = dedupe(items, db_path)  # 先去重，只 enrich 新片
        enrich(items)
        all_items.extend(items)

    report = render(all_items, min_score)
    if all_items and not dry_run:
        mark_pushed(all_items, db_path)
    return report
