"""movie-fetcher CLI 入口。

调用方式：
    PYTHON=/Users/stringzhao/workspace/martin/.venv/bin/python
    $PYTHON -m scripts.cli <subcommand> [args]

子命令：setup / search / download / status / subtitle / scan-missing / fetch
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Optional

import typer

# 允许直接 `python scripts/cli.py ...` 运行
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from scripts import config as cfg_mod  # type: ignore
    from scripts import nas as nas_mod  # type: ignore
    from scripts import search as search_mod  # type: ignore
    from scripts import download as dl_mod  # type: ignore
    from scripts import subtitle as sub_mod  # type: ignore
    from scripts import paths as paths_mod  # type: ignore
    from scripts import embed as embed_mod  # type: ignore
else:
    from . import config as cfg_mod
    from . import nas as nas_mod
    from . import search as search_mod
    from . import download as dl_mod
    from . import subtitle as sub_mod
    from . import paths as paths_mod
    from . import embed as embed_mod

app = typer.Typer(add_completion=False, no_args_is_help=True,
                  help="电影下载 + 字幕一体化工具")


# ─── setup ──────────────────────────────────────────────────────────────────


@app.command(help="探测 NAS 上的下载客户端并写入 config.yaml")
def setup(
    qbit_user: str = typer.Option("admin", help="qBit/Transmission 登录名"),
    qbit_password: str = typer.Option("", help="qBit/Transmission 登录密码"),
    nas_internal: str = typer.Option("", help="qBit 视角下的下载根目录，如 /volume1/.../迅雷下载"),
):
    data = cfg_mod.load()
    host = cfg_mod.require(data, "nas.host")

    typer.echo(f"[setup] 探测 {host} 常见客户端端口...")
    hits = nas_mod.probe(host)
    if not hits:
        typer.echo("  未发现存活端口；请手动检查 NAS 上 qBit/Transmission 是否启用 Web UI")
        typer.echo("  或者直接编辑 ~/.hermes/skills/media/movie-fetcher/config.yaml 填 client.url 等字段")
        raise typer.Exit(1)
    for kind, port in hits:
        typer.echo(f"  ✓ {host}:{port}  ({kind} 候选)")

    # 取第一个能成功握手的
    for kind, port in hits:
        url = f"http://{host}:{port}"
        if kind == "qbittorrent":
            ok, msg = nas_mod.try_qbit(url, qbit_user, qbit_password)
        else:
            ok, msg = nas_mod.try_transmission(host, port, qbit_user, qbit_password)
        typer.echo(f"  [{kind}] {msg}")
        if ok:
            data.setdefault("client", {})
            data["client"]["kind"] = kind
            data["client"]["url"] = url
            data["client"]["user"] = qbit_user
            data["client"]["password"] = qbit_password
            if nas_internal:
                data.setdefault("paths", {})["nas_internal"] = nas_internal
            cfg_mod.save(data)
            typer.echo(f"  写入 config.yaml: client.kind={kind}, url={url}")
            if not data.get("paths", {}).get("nas_internal"):
                typer.echo("  ⚠ 未设置 paths.nas_internal，请手动填入 NAS 内部下载路径")
            return
    typer.echo("  所有候选都握手失败；请确认凭据或在 config.yaml 中手填", err=True)
    raise typer.Exit(2)


# ─── search ─────────────────────────────────────────────────────────────────


@app.command(help="按标题搜索 BT 资源")
def search(
    title: str,
    limit: int = typer.Option(10, "--limit", "-n"),
    as_json: bool = typer.Option(False, "--json", help="JSON 输出"),
):
    data = cfg_mod.load()
    timeout = data.get("search", {}).get("timeout", 5)
    results = search_mod.search_all(title, timeout=timeout, limit=limit)
    if not results:
        typer.echo("无结果")
        raise typer.Exit(1)
    if as_json:
        typer.echo(json.dumps([r.to_dict() for r in results], ensure_ascii=False, indent=2))
        return
    typer.echo(f"{'src':<8} {'seed':>6}  {'size':<12}  title")
    typer.echo("-" * 80)
    for r in results:
        seed = "?" if r.seeders < 0 else str(r.seeders)
        typer.echo(f"{r.source:<8} {seed:>6}  {r.size:<12}  {r.title[:60]}")


# ─── helpers ────────────────────────────────────────────────────────────────


def _resolve_category(data: dict, category: str) -> str:
    """解析分类参数，兜底到 config 里的 default_category，校验合法性。"""
    categories = data["paths"].get("categories", {})
    if not category:
        category = data["paths"].get("default_category", "movie")
    if categories and category not in categories:
        valid = ", ".join(categories.keys())
        typer.echo(f"未知分类 '{category}'，支持：{valid}", err=True)
        raise typer.Exit(1)
    return category


# ─── download ───────────────────────────────────────────────────────────────


@app.command(help="推送 magnet 到 NAS；title 模式会先搜后选最佳")
def download(
    target: str = typer.Argument(..., help="magnet:... 或 电影标题"),
    category: str = typer.Option("", "--category", "-c",
                                 help="分类（电影/剧集），留空用 config 默认"),
):
    data = cfg_mod.load()
    category = _resolve_category(data, category)

    if target.startswith("magnet:"):
        magnet = target
    else:
        timeout = data.get("search", {}).get("timeout", 5)
        results = search_mod.search_all(target, timeout=timeout, limit=20)
        if not results:
            typer.echo("搜不到资源", err=True)
            raise typer.Exit(1)
        best = search_mod.pick_best(results, data["search"]["prefer_quality"])
        typer.echo(f"自动选中：[{best.source}] {best.title}  seeders={best.seeders}  size={best.size}")
        magnet = best.magnet

    client, hash_ = dl_mod.push_magnet(data, magnet, category=category)
    categories = data["paths"].get("categories", {})
    subdir = categories.get(category, "")
    target_path = f"迅雷下载/{subdir}" if subdir else "迅雷下载"
    typer.echo(f"已推送 → {target_path}，hash={hash_}")


# ─── status ─────────────────────────────────────────────────────────────────


@app.command(help="查看下载状态")
def status(hash_: Optional[str] = typer.Argument(None)):
    data = cfg_mod.load()
    client = nas_mod.build_client(data)
    if hash_:
        t = client.info(hash_)
        if not t:
            typer.echo("未找到任务", err=True)
            raise typer.Exit(1)
        typer.echo(f"{t.hash_}  {t.progress*100:.1f}%  {t.state}  {t.name}")
        return
    items = client.list()
    if not items:
        typer.echo("无任务")
        return
    for t in items:
        typer.echo(f"{t.hash_[:8]}…  {t.progress*100:5.1f}%  {t.state:<12}  {t.name[:60]}")


# ─── subtitle ───────────────────────────────────────────────────────────────


@app.command(help="为指定电影目录补字幕（中→英→whisper）")
def subtitle(
    movie_dir: str = typer.Argument(..., help="电影目录的本地挂载路径"),
    force: bool = typer.Option(False, "--force", help="即使已有字幕也强制下载"),
):
    data = cfg_mod.load()
    out = sub_mod.ensure_subtitle(Path(movie_dir), data, force=force)
    typer.echo(f"完成：新增 {len(out)} 个字幕")


@app.command("scan-missing", help="扫描所有分类目录列出缺字幕的电影/剧集")
def scan_missing(
    apply: bool = typer.Option(False, "--apply", help="对每个缺字幕的目录自动补"),
):
    data = cfg_mod.load()
    local_mount = Path(data["paths"]["local_mount"])
    categories = data["paths"].get("categories", {})

    # 若配置了分类，遍历所有分类子目录；否则只扫 local_mount 本身（向后兼容）
    scan_dirs: list[Path] = []
    if categories:
        for cat_name, cat_dir in categories.items():
            cat_path = local_mount / cat_dir
            if cat_path.is_dir():
                scan_dirs.append(cat_path)
            else:
                typer.echo(f"  ⚠ 分类目录不存在，跳过：{cat_path}")
    else:
        scan_dirs.append(local_mount)

    all_missing: dict[Path, list[Path]] = {}
    for scan_dir in scan_dirs:
        missing = sub_mod.scan_missing(scan_dir)
        if missing:
            all_missing[scan_dir] = missing

    if not all_missing:
        typer.echo("所有目录都有字幕 ✓")
        return

    total = sum(len(v) for v in all_missing.values())
    typer.echo(f"缺字幕的目录（{total} 个）：")
    for scan_dir, missing in all_missing.items():
        typer.echo(f"\n  [{scan_dir}]")
        for d in missing:
            typer.echo(f"    - {d.name}")

    if apply:
        typer.echo("\n开始批量补字幕...")
        for scan_dir, missing in all_missing.items():
            typer.echo(f"\n>>> [{scan_dir}]")
            for d in missing:
                typer.echo(f"  {d.name}")
                sub_mod.ensure_subtitle(d, data)


# ─── fetch (端到端) ─────────────────────────────────────────────────────────


@app.command(help="端到端：搜 → 选 → 推 → 等 metadata → 配字幕（默认不等下载完）")
def fetch(
    title: str,
    wait_download: bool = typer.Option(False, "--wait-download",
                                       help="等到视频下载 100% 完成再退出（默认只等 metadata）"),
    timeout: int = typer.Option(0, help="覆盖默认超时（秒），0 用配置默认"),
    category: str = typer.Option("", "--category", "-c",
                                 help="分类（电影/剧集），留空用 config 默认"),
):
    data = cfg_mod.load()
    category = _resolve_category(data, category)
    categories = data["paths"].get("categories", {})
    cat_subdir = categories.get(category, "")

    typer.echo(f">>> 搜索：{title}")
    s_timeout = data.get("search", {}).get("timeout", 5)
    results = search_mod.search_all(title, timeout=s_timeout, limit=20)
    if not results:
        typer.echo("搜不到资源", err=True)
        raise typer.Exit(1)
    best = search_mod.pick_best(results, data["search"]["prefer_quality"])
    typer.echo(f"  选中：[{best.source}] {best.title}  seeders={best.seeders}  size={best.size}")

    cat_label = f"迅雷下载/{cat_subdir}" if cat_subdir else "迅雷下载"
    typer.echo(f">>> 推送到 NAS → {cat_label}")
    client, hash_ = dl_mod.push_magnet(data, best.magnet, category=category)
    typer.echo(f"  hash={hash_}")

    typer.echo(">>> 等待 metadata...")

    def tick_meta(t):
        typer.echo(f"  state={t.state}  name={t.name[:60]}")

    meta_timeout = timeout if (timeout and not wait_download) else 600
    t = dl_mod.wait_for_metadata(client, hash_, poll_interval=3, timeout=meta_timeout, on_tick=tick_meta)
    if t is None or not t.name:
        typer.echo("  超时未拿到 metadata；任务保留，可后续用 `status` 跟进", err=True)
        raise typer.Exit(2)
    typer.echo(f"  ✓ metadata 就绪：{t.name}")

    typer.echo(">>> 配字幕（zimuku → SubHD → subliminal，不依赖视频下载完成）")
    target_dir = Path(paths_mod.local_category_dir(
        data["paths"]["local_mount"], categories, category))
    target_dir.mkdir(parents=True, exist_ok=True)
    got = sub_mod.subtitle_for_name(t.name, target_dir, data)

    if wait_download:
        typer.echo(">>> 继续等待下载完成...")
        interval = data.get("download", {}).get("poll_interval", 30)
        dl_timeout = timeout or data.get("download", {}).get("poll_timeout", 86400)

        def tick_dl(tt):
            typer.echo(f"  {tt.progress*100:5.1f}%  {tt.state}  {tt.name[:50]}")

        res = dl_mod.wait_for_completion(client, hash_, poll_interval=interval, timeout=dl_timeout, on_tick=tick_dl)
        if res.completed and got is None:
            typer.echo(">>> 下载完成；重试字幕（含 whisper 兜底）")
            local_dir = Path(paths_mod.to_local(
                f"{res.task.save_path}/{res.task.name}" if res.task else "",
                data["paths"]["nas_internal"], data["paths"]["local_mount"]))
            if local_dir.is_dir():
                sub_mod.ensure_subtitle(local_dir, data)
            elif local_dir.is_file():
                sub_mod.ensure_subtitle(local_dir.parent, data)

    if got:
        typer.echo(f"完成。字幕：{got}")
    else:
        typer.echo("完成。未自动配到字幕（zimuku/SubHD/subliminal 无匹配）；下载完后可单跑 `subtitle <dir>` 走 whisper 兜底。")


# ─── embed ──────────────────────────────────────────────────────────────────


@app.command(help="把外挂字幕用 ffmpeg -c copy 内嵌到 mkv（视频不重新编码）")
def embed(
    target: str = typer.Argument(..., help="mkv 文件或目录（目录会递归处理）"),
    no_default: bool = typer.Option(False, "--no-default", help="不把新字幕标为 default"),
    delete_external: bool = typer.Option(False, "--delete-external", help="内嵌后删除外挂 srt/ass"),
):
    p = Path(target)
    if not p.exists():
        typer.echo(f"路径不存在：{p}", err=True)
        raise typer.Exit(1)
    if p.is_file():
        embed_mod.embed(p, set_default=not no_default, keep_external=not delete_external)
    else:
        changed = embed_mod.embed_dir(p, set_default=not no_default, keep_external=not delete_external)
        typer.echo(f"完成：内嵌了 {len(changed)} 个 mkv")


if __name__ == "__main__":
    app()
